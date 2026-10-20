# A site or a unit at a site. Reactor units point at their site via parent.
# facility_type and status stay blank until a source states them.
class Facility < ApplicationRecord
  include Verifiable
  include Sluggable
  include Hierarchical

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

  after_save :hand_plain_slug_to_site, if: -> { saved_change_to_parent_id? && parent_id }

  normalizes :nrc_docket, with: ->(docket) { docket.strip.presence }
  normalizes :eia_plant_id, with: ->(id) { id.to_s.strip.presence }
  normalizes :country_code, with: ->(code) { code.strip.upcase }

  validates :name, presence: true
  # A display label for tight spots ("Vogtle"), never an identity key or
  # matched on (DATA.md, Names).
  normalizes :short_name, with: ->(name) { name.squish.presence }
  validates :short_name, length: { maximum: 30 }, allow_nil: true
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

  # A site owns the plain slug of its name (#333). NRC units often came
  # first and took it, leaving the site at "palisades-2"; a unit's page is
  # only a #unit- anchor on its site's, so the unit moves to "<slug>-unit".
  # Only the site's own unit is ever moved, never another plant's.
  # Returns [[site, old slug, unit, unit's old slug], ...] for what it moved.
  # Safe to run again: a site already at its plain slug is left alone. The
  # old slugs are kept (Sluggable), so they 301 to the site.
  def self.give_sites_their_plain_slugs!
    where(parent_id: nil).where("slug ~ ?", "-[0-9]+$").order(:id).filter_map { |site| give_site_its_plain_slug!(site) }
  end

  # The same for one site, or nil when there's nothing to move. unit: the
  # site's unit already in hand (the one being grouped under it), if any.
  def self.give_site_its_plain_slug!(site, unit = nil)
    plain = site.name.to_s.parameterize
    return unless site.parent_id.nil? && site.slug.to_s.match?(/\A#{Regexp.escape(plain)}-\d+\z/)

    unit ||= where(parent_id: site.id).find_by(slug: plain)
    return unless unit && unit.parent_id == site.id && unit.slug == plain
    # The unit's new slug must be exactly "<plain>-unit", so its row's old
    # anchor ("#unit-<plain>") can only be its own (unit_anchors). If that's
    # taken, leave the pair for a person.
    return if where(slug: "#{plain}-unit").exists?

    moved = [ site, site.slug, unit, unit.slug ]
    transaction do
      # Written directly, so a save that grouped this unit keeps its own
      # saved_changes (the fact writer audits them). The unit's old slug
      # becomes the site's, so it isn't kept as the unit's former slug.
      unit.update_columns(slug: "#{plain}-unit", updated_at: Time.current)
      # A live slug wins over an old one (as Sluggable does on save), so an
      # old address of another plant can't redirect there any more.
      FormerSlug.where(sluggable_type: base_class.name, slug: "#{plain}-unit").delete_all
      site.update!(slug: plain)
    end
    moved
  end

  # The plant page's anchor for a unit, and the old one a unit moved by
  # give_site_its_plain_slug! had ("#unit-palisades"), so old links still
  # reach its row. Read from the unit's slug alone ("<old>-unit"), which a
  # later rename of the unit or its site doesn't change. taken: the other
  # rows' slugs on the page, so an extra anchor never repeats an id there.
  def unit_anchors(taken = [])
    old = slug.to_s.delete_suffix("-unit") if parent_id && slug.to_s.end_with?("-unit")
    [ "unit-#{slug}", ("unit-#{old}" if old.present? && !taken.include?(old)) ].compact
  end

  private
    # When a unit is grouped under its site (#333: NRC units usually come
    # first), the site takes back its plain slug if this unit holds it.
    def hand_plain_slug_to_site
      self.class.give_site_its_plain_slug!(parent, self)
    end

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
