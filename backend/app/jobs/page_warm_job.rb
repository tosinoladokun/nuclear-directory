require "app_hosts"

# Keeps the page cache (#707) warm (PM, 3 Nov): after the data changes, it
# rebuilds in the background only the pages the change touched (each company
# and plant page has its own stamp, PageStamps), and the home cards when the
# directory changed, so no visitor waits for a first build (GE Vernova's took
# 3.6 s live).
#
# Debounced (Infra): it rebuilds only once the data has stood still for a
# whole tick (what it saw last time is what it sees now), so a crawl or a
# burst of approvals is handled once, after it ends. After each page it rests
# three times as long as the page took, so it uses at most about a quarter of the
# CPU, and it stops if the data changes again (the next quiet tick finishes).
# Most connected pages first.
#
# Pages are built for the site's public address (the first of APP_HOSTS, or
# WARM_HOST), over https, the same key a visitor's request uses.
class PageWarmJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "page_warm", duration: 1.hour if respond_to?(:limits_concurrency)

  WARMED = "page_warm/warmed"
  WARMED_DATA = "page_warm/warmed_data"
  SEEN = "page_warm/seen"
  PAUSE = 0.1
  REST = 3

  def perform(pause: PAUSE, debounce: true)
    return unless (host = self.class.host)

    # A tick reads only the cheap DataVersion; the page stamps are computed
    # once per data change, after it goes quiet (Infra).
    data = DataVersion.current
    return if Rails.cache.read(WARMED_DATA) == data

    seen = Rails.cache.read(SEEN)
    Rails.cache.write(SEEN, data)
    return if debounce && seen != data

    now = state(data)
    warmed = Rails.cache.read(WARMED) || {}
    todo = pages(host).reject { |key, _| warmed[key] == now[key] }
    todo.each do |key, draw|
      return unless DataVersion.current == data

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      draw.call
      warmed[key] = now[key]
      Rails.cache.write(WARMED, warmed)
      sleep [ pause, REST * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) ].max if pause.positive?
    end
    Rails.cache.write(WARMED_DATA, data)
  end

  def self.host = ENV["WARM_HOST"].presence || AppHosts.from_env(ENV).first

  private

  # What each page's cache key rests on: { "home" => DataVersion, ["company", id] => its version, … }.
  def state(data)
    map = PageStamps.map(data)
    { "home" => data }
      .merge(map[:company].transform_keys { |id| [ "company", id ] })
      .merge(map[:plant].transform_keys { |id| [ "plant", id ] })
  end

  # [ key, draw ] for every page, most connected first. Each is drawn as a
  # request for its own path would draw it (the page links to its own address,
  # e.g. "Report a correction").
  def pages(host)
    urls = Rails.application.routes.url_helpers
    draw = ->(controller, path, template, assigns) { controller.renderer.new(http_host: host, https: true, "PATH_INFO" => path).render(template:, assigns:) }
    [ [ "home", -> { draw.call(HomeController, urls.root_path, "home/show", { suggestions: HomeSuggestions.pick }) } ] ] +
      DirectoryListing.new.companies.map do |organization|
        [ [ "company", organization.id ],
          -> { draw.call(CompaniesController, urls.company_path(slug: organization.slug), "companies/show", { organization:, load_profile: -> { CompanyProfile.new(organization) } }) } ]
      end +
      DirectoryListing.new(category: "plants").plants.map do |site|
        [ [ "plant", site.id ], -> { draw.call(PlantsController, urls.plant_path(slug: site.slug), "plants/show", { site:, load_profile: -> { PlantProfile.new(site) } }) } ]
      end
  end
end
