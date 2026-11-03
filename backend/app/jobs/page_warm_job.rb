require "app_hosts"


# Keeps the page cache (#707) warm (PM, 3 Nov): after the data changes, it
# builds the home cards and every company and plant page in the background,
# so no visitor waits for a first build (GE Vernova's took 3.6 s live).
# Most connected first, since those pages are visited most. It pauses
# between pages so the web process it shares stays responsive, and stops
# early when the data changes again (the next run starts over).
#
# Pages are built for the site's public address (the first of APP_HOSTS, or
# WARM_HOST), over https, the same key a visitor's request uses.
class PageWarmJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "page_warm", duration: 1.hour if respond_to?(:limits_concurrency)

  WARMED = "page_warm/version"
  SEEN = "page_warm/seen"
  PAUSE = 0.1
  # After each page it rests twice as long as the page took: at most about a third of the CPU (Infra).
  REST = 2

  # Debounced (Infra): it warms only once the data has stood still for a whole
  # tick (the version it saw last time is the version now), so a crawl or a
  # burst of approvals is warmed once, after it ends.
  def perform(pause: PAUSE, debounce: true)
    version = DataVersion.current
    return if Rails.cache.read(WARMED) == version
    return unless (host = self.class.host)
    if debounce && Rails.cache.read(SEEN) != version
      Rails.cache.write(SEEN, version)
      return
    end

    pages(host).each do |render|
      return unless DataVersion.current == version

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      render.call
      sleep [ pause, REST * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) ].max if pause.positive?
    end
    Rails.cache.write(WARMED, version)
  end

  def self.host = ENV["WARM_HOST"].presence || AppHosts.from_env(ENV).first

  private

  # Each page is drawn as a request for its own path would draw it (the page
  # links to its own address, e.g. "Report a correction").
  def pages(host)
    urls = Rails.application.routes.url_helpers
    draw = ->(controller, path, template, assigns) { controller.renderer.new(http_host: host, https: true, "PATH_INFO" => path).render(template:, assigns:) }
    [ -> { draw.call(HomeController, urls.root_path, "home/show", { suggestions: HomeSuggestions.pick }) } ] +
      DirectoryListing.new.companies.map do |organization|
        -> { draw.call(CompaniesController, urls.company_path(slug: organization.slug), "companies/show", { organization:, load_profile: -> { CompanyProfile.new(organization) } }) }
      end +
      DirectoryListing.new(category: "plants").plants.map do |site|
        -> { draw.call(PlantsController, urls.plant_path(slug: site.slug), "plants/show", { site:, load_profile: -> { PlantProfile.new(site) } }) }
      end
  end
end
