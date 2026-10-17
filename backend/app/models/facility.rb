# A site or a unit at a site. Reactor units point at their site via parent.
# facility_type and status stay blank until a source states them.
class Facility < ApplicationRecord
  include Verifiable
  include Sluggable
  include Hierarchical

  # An EIA site and an NRC unit can share a name, so a taken slug falls back
  # to "-2" (#134). Organization doesn't opt in (#154).
  self.suffixes_slug = true

  enum :facility_type, %w[power_reactor research_reactor fuel_facility enrichment fusion_facility uranium_mine mill other]
    .index_by(&:itself),
    validate: { allow_nil: true }
  # not_operating: licensed, but producing no power (not shut down for good).
  # Rails' own scopes are off: they'd add "not_<status>" opposites, and its
  # not_operating (status isn't operating) would collide with this status.
  # One scope per status instead, so Facility.not_operating is exactly that.
  STATUSES = %w[operating not_operating under_construction planned shut_down decommissioning].freeze
  enum :status, STATUSES.index_by(&:itself), validate: { allow_nil: true }, scopes: false
  STATUSES.each { |status| scope status, -> { where(status:) } }

  belongs_to :technology, optional: true
  has_many :facility_relationships, dependent: :destroy
  has_many :organizations, -> { distinct }, through: :facility_relationships
  has_many :aliases, class_name: "FacilityAlias", dependent: :destroy

  normalizes :nrc_docket, with: ->(docket) { docket.strip.presence }
  normalizes :eia_plant_id, with: ->(id) { id.to_s.strip.presence }
  normalizes :country_code, with: ->(code) { code.strip.upcase }

  validates :name, presence: true
  validates :nrc_docket, uniqueness: true, allow_nil: true
  # One site per EIA plant (#121); only sites carry it.
  validates :eia_plant_id, uniqueness: { conditions: -> { where(parent_id: nil) } }, allow_nil: true
  validates :eia_plant_id, absence: { message: "belongs on the site, not a unit" }, if: -> { parent_id || nrc_docket }
  validates :country_code, length: { is: 2 }
  validates :capacity_mw, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true
  validate :sites_and_units_only

  # What the public sees. A unit: verified, under a site that isn't rejected
  # or unpublished. A site: verified, or pending with at least one such unit
  # (#73: a site made from NRC units goes public with its first verified unit).
  def self.published
    closed_sites = where(parent_id: nil, verification_status: Verifiable::CLOSED_STATUSES).select(:id)
    units = verified.where.not(parent_id: nil).where.not(parent_id: closed_sites)
    sites = where(parent_id: nil)
    sites.verified.or(sites.pending.where(id: units.select(:parent_id))).or(units)
  end

  private
    # Two levels only: a site, and units under it. Publication (and the
    # directory's rollups) rely on a unit's parent being its site.
    def sites_and_units_only
      # The parent record itself, so an unsaved chain (built in memory, saved
      # together) is checked too, not just a saved parent_id.
      return unless parent

      errors.add(:parent, "must be a site, not a unit") if parent.parent_id || parent.parent
      errors.add(:parent, "can't be set: this site has units of its own") if (persisted? && children.exists?) || children.any?
    end
end
