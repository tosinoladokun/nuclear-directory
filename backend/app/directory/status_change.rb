# A person sets a plant's or its units' status (#316): the one code path
# behind `directory:set_status` and the admin's Change status. It's written
# through FactWriter as a human decision, verified, with the reason and any
# evidence, so it's final: a crawler's other value only counts as overruled.
#
#   plan = Directory::StatusChange.plan(ids: [171, 174], status: "not_operating")
#   plan.changes          # => [Change(id: 171, name: "Palisades", unit: false, from: "operating", to: "not_operating"), …]
#   plan.operating_before # => 55 (published plants, sites, that are operating)
#   Directory::StatusChange.apply(ids: [171, 174], status: "not_operating", by: "human:tosin",
#     reason: "…", source_id: 12, quote: "10/14/2026 12:00:00 AM|Palisades|0")
#
# Both raise Invalid for an unknown status, malformed or missing ids, or
# records that aren't one plant (a site and its units): one piece of
# evidence backs them all; or a record that's taken off or rejected (a
# status change approves, so it would put it back: that's Put back's job).
# apply also needs that evidence, a source and its quote: a published status
# always has one (docs/DATA.md). A record already at the status is left alone.
module Directory::StatusChange
  class Invalid < StandardError; end

  Change = Data.define(:id, :name, :unit, :from, :to)
  # changes: what would change (or did); unchanged: records already at the
  # status. operating_*: the directory's published plants that are operating,
  # before and after.
  Plan = Data.define(:status, :changes, :unchanged, :operating_before, :operating_after)

  STATUSES = Facility.statuses.keys.freeze
  BUSY = "Someone was changing this plant just then. Try again.".freeze

  def self.plan(ids:, status:) = plan_for(load(ids, status), status)

  # Writes the plan as `by`'s decision, in one transaction under row locks,
  # with the source and quote as evidence, and returns it.
  def self.apply(ids:, status:, by:, reason:, source_id: nil, quote: nil)
    raise Invalid, "Say who made the change" unless by.to_s.match?(/\Ahuman:\S+\z/)
    raise Invalid, "Give a reason" if reason.blank?
    raise Invalid, "Give a source and the quote from it that states the status" if source_id.blank? || quote.blank?

    Facility.transaction do
      facilities = load(ids, status, lock: true)
      plan = plan_for(facilities, status)
      evidence = [ { source_id:, quote:, found_by: "human" } ]
      plan.changes.each do |change|
        result = Directory::FactWriter.write(:facility, { id: change.id, status: },
          evidence:, verification: { status: "verified", by:, reason: })
        raise Invalid, "#{change.name} (##{change.id}): #{result.errors.to_sentence}" unless result.ok?
      end
      plan
    end
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    raise Invalid, BUSY
  end

  # NRC's 365-day power status file as last fetched, and its newest line for
  # this plant ("10/14/2026 12:00:00 AM|Palisades|0"): [source_id, quote], or
  # nil when the file isn't fetched or doesn't name the plant.
  def self.nrc_quote(name)
    source = nrc_status_file or return
    dated = ->(line) { Time.strptime(line.split("|").first.to_s, "%m/%d/%Y %I:%M:%S %p") rescue Time.at(0) }
    quote = source.content_text.to_s.lines.map(&:strip).grep(/\|#{Regexp.escape(name)}\|/i).max_by(&dated)
    [ source.id, quote ] if quote
  end

  # NRC's status file as last fetched, or nil.
  def self.nrc_status_file = Source.where(source_kind: "nrc_power_status").order(fetched_at: :desc).first

  def self.load(ids, status, lock: false)
    raise Invalid, "Unknown status #{status.inspect}" unless STATUSES.include?(status.to_s)

    tokens = Array(ids).flat_map { |id| id.to_s.split }
    raise Invalid, "Give one or more record ids, as whole numbers" unless tokens.any? && tokens.all? { |token| token.match?(/\A[1-9]\d*\z/) }

    ids = tokens.map(&:to_i).uniq
    # Units before their site, as FactWriter locks them, so two writers never
    # wait on each other.
    scope = Facility.where(id: ids).order(Arel.sql("parent_id IS NULL, id"))
    facilities = (lock ? scope.lock : scope).index_by(&:id)
    raise Invalid, "No facility #{(ids - facilities.keys).join(', ')}" if (ids - facilities.keys).any?
    raise Invalid, "These aren't one plant (a site and its units), so one piece of evidence can't back them all" if
      facilities.values.map { |facility| facility.parent_id || facility.id }.uniq.many?
    closed = facilities.values.select(&:closed?)
    raise Invalid, "#{closed.map(&:name).uniq.to_sentence} #{closed.one? ? 'is' : 'are'} taken off or rejected. Put it back first." if closed.any?

    ids.map { |id| facilities.fetch(id) }
  end

  def self.plan_for(facilities, status)
    changing, unchanged = facilities.partition { |facility| facility.status != status }
    changes = changing.map { |facility| Change.new(id: facility.id, name: facility.name, unit: facility.parent_id.present?, from: facility.status, to: status) }
    before = operating_plants
    Plan.new(status:, changes:, unchanged: unchanged.map { |facility| Change.new(id: facility.id, name: facility.name, unit: facility.parent_id.present?, from: status, to: status) },
      operating_before: before, operating_after: before - counted_now(facilities) + counted_after(facilities, changes, status))
  end

  # The plant's site, as the directory's operating count sees it now (1 or 0)
  # and once the changes are written (each verified, so a site, or a
  # pending site's unit, goes public with them).
  def self.site_of(facilities)
    first = facilities.first
    first.parent_id ? (facilities.find { |facility| facility.id == first.parent_id } || first.parent) : first
  end

  def self.counted_now(facilities)
    site = site_of(facilities)
    site.operating? && Facility.published.exists?(id: site.id) ? 1 : 0
  end

  def self.counted_after(facilities, changes, status)
    site = site_of(facilities)
    site_changes = changes.any? { |change| change.id == site.id }
    operating = site_changes ? status == "operating" : site.operating?
    published = site_changes || Facility.published.exists?(id: site.id) || (site.pending? && changes.any?(&:unit))
    operating && published ? 1 : 0
  end

  def self.operating_plants = Facility.published.where(parent_id: nil, status: "operating").count

  private_class_method :load, :plan_for, :operating_plants, :site_of, :counted_now, :counted_after
end
