# A page or dataset we crawl. source_kind names the crawler plug-in that
# handles it (e.g. nrc_reactor_list, web_page).
class Source < ApplicationRecord
  enum :crawl_status, %w[pending ok blocked needs_human].index_by(&:itself), default: "pending", validate: true,
    prefix: :crawl

  has_many :evidence, dependent: :restrict_with_error
  has_many :candidates, dependent: :restrict_with_error

  # A bare homepage has one address, without the trailing slash
  # ("https://www.mit.edu/" is "https://www.mit.edu"), so a crawler, Enrich
  # and the seed land on one row (#670). Lookups are normalised too.
  normalizes :url, with: ->(url) { bare_homepage(url.strip) }

  def self.bare_homepage(url)
    url.match?(%r{\Ahttps?://[^/?#\s]+/\z}i) ? url.chomp("/") : url
  end

  before_validation { self.domain ||= domain_from_url }

  validates :url, presence: true, uniqueness: true
  validate :url_is_a_web_address
  validates :source_kind, presence: true

  # Absolute http(s) URLs only. Sources are shown as links, so anything else
  # (javascript:, data:, a relative path) must never be stored (#79).
  def self.web_address?(url)
    uri = URI.parse(url.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present? && !url.to_s.match?(/\s/)
  rescue URI::InvalidURIError
    false
  end

  private
    def url_is_a_web_address
      return if url.blank? || self.class.web_address?(url)

      errors.add(:url, "must be an absolute http or https address")
    end

    def domain_from_url
      URI.parse(url.to_s).host&.downcase&.delete_prefix("www.")
    rescue URI::InvalidURIError
      nil
    end
end
