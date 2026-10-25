class Organization < ApplicationRecord
  include Verifiable
  include Sluggable

  enum :status, %w[active acquired defunct].index_by(&:itself), default: "active", validate: true

  has_many :aliases, class_name: "OrganizationAlias", dependent: :destroy
  has_many :organization_roles, dependent: :destroy
  has_many :roles, through: :organization_roles
  has_many :organization_technologies, dependent: :destroy
  has_many :technologies, through: :organization_technologies
  has_many :outgoing_relationships, class_name: "Relationship", foreign_key: :from_organization_id,
    inverse_of: :from_organization, dependent: :destroy
  has_many :incoming_relationships, class_name: "Relationship", foreign_key: :to_organization_id,
    inverse_of: :to_organization, dependent: :destroy
  has_many :facility_relationships, dependent: :destroy
  has_many :facilities, -> { distinct }, through: :facility_relationships

  normalizes :domain, with: ->(domain) { Organization.domain_from(domain) }
  normalizes :country_code, with: ->(code) { code.strip.upcase.presence }

  validates :name, presence: true
  validates :domain, uniqueness: true, allow_nil: true
  # The SEC's Central Index Key (#129), stored as EDGAR writes it: 10 digits,
  # zero-padded ("320193" and "CIK0000320193" are "0000320193").
  normalizes :sec_cik, with: ->(cik) { Organization.cik_from(cik) }
  validates :sec_cik, format: { with: /\A\d{10}\z/ }, uniqueness: true, allow_nil: true
  # EIA's utility ID (#382), as EIA-860 writes it: a plain number ("7140").
  normalizes :eia_utility_id, with: ->(id) { id.to_s.strip.sub(/\A0+(?=\d)/, "").presence }
  validates :eia_utility_id, format: { with: /\A[1-9]\d{0,6}\z/ }, uniqueness: true, allow_nil: true
  # A display label for tight spots ("Oglethorpe", "MEAG"), never an identity
  # key or matched on (DATA.md, Names).
  normalizes :short_name, with: ->(name) { name.squish.presence }
  validates :short_name, length: { maximum: 30 }, allow_nil: true
  # A list row's middle column (#559): a label, 40 characters at most.
  normalizes :short_description, with: ->(text) { text.squish.presence }
  validates :short_description, length: { maximum: ShortDescription::MAX }, allow_nil: true
  # Blank when no source states it yet.
  validates :country_code, length: { is: 2 }, allow_nil: true
  validates :founded_year, numericality: { only_integer: true, in: 1800..2100 }, allow_nil: true

  # "https://www.TerraPower.com/news" and " terrapower.com " both give "terrapower.com".
  # 10 digits, zero-padded, or nil when blank. Anything that isn't 1 to 10
  # digits (after a "CIK" prefix) is kept as given, so validation refuses it.
  def self.cik_from(value)
    text = value.to_s.strip.presence or return
    digits = text.sub(/\ACIK/i, "")
    digits.match?(/\A\d{1,10}\z/) ? digits.rjust(10, "0") : text
  end

  def self.domain_from(url_or_domain)
    text = url_or_domain.to_s.strip
    host = text.include?("://") ? URI.parse(text).host : text.split("/").first
    host.to_s.downcase.delete_prefix("www.").presence
  rescue URI::InvalidURIError
    nil
  end
end
