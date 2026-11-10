require "net/http"


# IndexNow (#742, Tosin 9 Nov): tells Bing (which ChatGPT search and
# Copilot read) and the other IndexNow engines which public pages changed, so
# they're recrawled soon. Off unless INDEXNOW_KEY is set (Render env, never
# the repo); the key file is served at /<key>.txt (IndexNowController).
#
# The page warmer (PageWarmJob) calls note_changes once per data change, after
# the data goes quiet, with the page stamp map: the company and plant pages
# whose own stamp moved, plus the lists, topic pages, home and /updates. They
# collect and go in one batch at most every WINDOW (flush, every warmer tick).
# A failed send is tried once more, then logged and dropped.
module IndexNow
  ENDPOINT = URI("https://api.indexnow.org/indexnow")
  WINDOW = 10.minutes
  MAX_URLS = 10_000
  SENT = "indexnow/stamps"
  PENDING = "indexnow/pending"
  LAST_SENT = "indexnow/last_sent_at"

  # (uri, json) => true when the engine accepted it. Tests replace it.
  # Short timeouts: it runs inside the warmer job, which a hung endpoint mustn't hold (Infra).
  TIMEOUT = 8
  mattr_accessor :sender, default: lambda { |uri, json|
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT) do |http|
      http.post(uri.path, json, "Content-Type" => "application/json; charset=utf-8").code.to_i.between?(200, 299)
    end
  }

  # The key IndexNow checks against /<key>.txt: 8 to 128 letters, digits or dashes.
  def self.key = ENV["INDEXNOW_KEY"].to_s.then { |value| value if value.match?(/\A[a-zA-Z0-9-]{8,128}\z/) }

  # map: PageStamps.map ({ company: { id => version }, plant: { id => version } }). A version ends with the
  # page's own stamp; the deploy and the date in front of it don't count as a change.
  def self.note_changes(map, host:)
    return unless key && host

    stamps = map.to_h { |kind, versions| [ kind, versions.transform_values { |version| version.to_s.split("/").last } ] }
    sent = Rails.cache.read(SENT) || {}
    changed = stamps.to_h { |kind, now| [ kind, now.reject { |id, stamp| sent.dig(kind, id) == stamp }.keys ] }
    # A page taken off changes the lists, home and /updates though no other stamp moves.
    removed = sent.any? { |kind, before| (before.keys - stamps.fetch(kind, {}).keys).any? }
    Rails.cache.write(SENT, stamps)
    return if changed.values.all?(&:empty?) && !removed

    add(changed_paths(changed).map { |path| "https://#{host}#{path}" })
  end

  # The public pages a change may show on: the changed company and plant pages, and every list, topic page,
  # home and /updates (cheap to list, and any change can move their counts).
  def self.changed_paths(changed)
    urls = Rails.application.routes.url_helpers
    [
      urls.root_path, urls.updates_path, urls.companies_path,
      *Category.all.map { |category| urls.companies_path(category: category.to_param) },
      *PublicPages.new.tags.map { |tag| urls.companies_path(tag: tag.to_param) },
      *Organization.published.where(id: changed[:company]).pluck(:slug).map { |slug| urls.company_path(slug:) },
      *Facility.published.where(id: changed[:plant]).pluck(:slug).map { |slug| urls.plant_path(slug:) }
    ].reject { |path| SitemapsController::DISALLOWED.any? { |off| path == off || path.start_with?("#{off}/", "#{off}?") } }
  end

  # Everything waiting is kept; each batch takes at most MAX_URLS and leaves the rest for the next window.
  def self.add(new_urls) = Rails.cache.write(PENDING, (Rails.cache.read(PENDING) || []) | new_urls)

  # Sends what's waiting, in one batch, unless a batch went in the last WINDOW.
  def self.flush(host:)
    return unless key && host
    pending = Rails.cache.read(PENDING).presence or return
    last = Rails.cache.read(LAST_SENT)
    return if last && Time.zone.at(last) > WINDOW.ago

    batch, rest = pending.first(MAX_URLS), pending.drop(MAX_URLS)
    json = { host:, key:, keyLocation: "https://#{host}/#{key}.txt", urlList: batch }.to_json
    Rails.cache.write(LAST_SENT, Time.current.to_f)
    rest.any? ? Rails.cache.write(PENDING, rest) : Rails.cache.delete(PENDING)
    return true if send_once(json) || send_once(json)

    Rails.logger.warn("IndexNow: #{batch.size} URLs not accepted after a retry")
    false
  end

  def self.send_once(json)
    sender.call(ENDPOINT, json)
  rescue StandardError => e
    Rails.logger.warn("IndexNow: #{e.class}: #{e.message}")
    false
  end
end
