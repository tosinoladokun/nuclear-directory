# The admin's Live list (#201): every record of a tab, narrowed by a search
# and by Directory::Checks tags, with each tag's count for what's shown.
# Status is one choice (Live by default); within the other groups chips are
# OR, and groups combine with AND. A chip's count is what the list would
# show with it added, given everything chosen in the other groups.
#
#   list = Directory::LiveList.new(tab: "plants", query: "vogtle", chosen: { "flags" => [ "single-source" ] })
#   list.total            # => 3
#   list.page(1)          # => [Directory::LiveList::Row, …]
#   list.count("no-owner") # => 2
class Directory::LiveList
  # What each tab lists: per model, a relation of its records.
  TABS = {
    "all" => -> { { "Organization" => Organization.all, "Facility" => Facility.where(parent_id: nil) } },
    "companies" => -> { { "Organization" => Organization.all } },
    "plants" => -> { { "Facility" => Facility.where(parent_id: nil) } },
    "reactors" => -> { { "Facility" => Facility.where.not(nrc_docket: nil) } },
    "links" => -> { { "Relationship" => Relationship.all, "FacilityRelationship" => FacilityRelationship.all } }
  }.freeze
  # All of a source's records (within, on the All tab): every company,
  # plant, reactor (with or without a docket) and link it backs, as
  # SourceCatalog counts them, so a Facts count opens to that many.
  EVERYTHING = -> { { "Organization" => Organization.all, "Facility" => Facility.all, "Relationship" => Relationship.all, "FacilityRelationship" => FacilityRelationship.all } }
  TAB_LABELS = { "all" => "All", "companies" => "Companies", "plants" => "Plants", "reactors" => "Reactors", "links" => "Links" }.freeze
  # What a tab counts, so a count reads as records of that kind (Data Quality, #283).
  # [one, many]
  TAB_NOUNS = { "all" => [ "record", "companies and plants" ], "companies" => %w[company companies], "plants" => %w[plant plants],
    "reactors" => %w[reactor reactors], "links" => %w[link links] }.freeze
  DEFAULT_STATUS = "live"
  PAGE = 50

  # One record in the list. flags: labels of its flags and gaps, most urgent first.
  Row = Data.define(:type, :id, :name, :kind, :status, :flags, :changed_at)

  attr_reader :tab, :query, :chosen, :within

  # within: a Sources row or document key (SourceCatalog), to list only what its sources back.
  def initialize(tab: "all", query: nil, chosen: {}, within: nil)
    @tab = TABS.key?(tab) ? tab : "all"
    @query = query.to_s.strip.presence
    @within = within.to_s.presence
    @chosen = Directory::Checks::GROUPS.keys.to_h do |group|
      keys = Array(chosen[group]).map(&:to_s) & Directory::Checks.in_group(group).map(&:key)
      [ group, Directory::Checks::SINGLE.include?(group) ? keys.first(1) : keys ]
    end
    @chosen["status"] = [ DEFAULT_STATUS ] if @chosen["status"].empty?
  end

  # Counted from the filtered ids, without ordering them (each tab's count needs only this).
  def total = @keys ? @keys.size : filtered(nil).values.sum(&:size)

  # This tab's records with the chosen status only (its count on the tab).
  # Within a source (within), the count of what that source backs in the tab.
  # Cached until the directory or a claim changes (Infra, 18 Nov: five tab counts ran a heavy count each, every load).
  def self.tab_count(tab, status: DEFAULT_STATUS, within: nil)
    Rails.cache.fetch([ "live-tab-count", stamp, tab, status, within ], expires_in: 10.minutes) do
      new(tab:, chosen: { "status" => [ status ] }, within:).total
    end
  end

  # What the counts and tags rest on: the directory (DataVersion) and the claims Data Quality's tags read.
  # Read once per request (CurrentAttributes resets it), not once per tag.
  def self.stamp = (Current.live_stamp ||= [ DataVersion.current, Candidate.maximum(:updated_at)&.to_f ].join("/"))

  # A tag's ids for a model, shared by every list in this and later requests until something changes (Infra).
  def self.tag_ids(tag, type)
    Rails.cache.fetch([ "live-tag-ids", stamp, tag.key, type ], expires_in: 10.minutes) { tag.ids(type.constantize) }.to_set
  end

  # [type, id] of every record shown, in order (newest change first).
  def keys
    @keys ||= begin
      matching = filtered(nil)
      ordered = matching.flat_map do |type, ids|
        type.constantize.where(id: ids.to_a).pluck(:id, :updated_at).map { |id, at| [ type, id, at ] }
      end
      ordered.sort_by { |type, id, at| [ -at.to_f, type, id ] }.map { |type, id, _| [ type, id ] }
    end
  end

  def page(number)
    slice = keys.drop((number - 1) * PAGE).first(PAGE)
    rows_for(slice)
  end

  # How many records the list would show with this tag chosen as well: with
  # the group's other chosen tags (OR), or instead of the status (Status is one choice).
  def count(key)
    tag = Directory::Checks.find(key) or return 0
    together = Directory::Checks::SINGLE.include?(tag.group) ? [ tag ] : (chosen[tag.group] | [ key ]).map { |chosen_key| Directory::Checks.find(chosen_key) }
    filtered(tag.group).sum { |type, ids| (ids & together.map { |each_tag| tag_ids(each_tag, type) }.reduce(:|)).size }
  end

  # Where a record sits in the list, for Previous and Next on its page.
  def neighbours(type, id)
    index = keys.index([ type, id ]) or return
    { index: index + 1, total: keys.size, previous: (keys[index - 1] if index.positive?), next: keys[index + 1] }
  end

  def chosen?(key) = chosen.values.flatten.include?(key)
  # What the footer's count is of: [one, many].
  def nouns = within && tab == "all" ? %w[record records] : TAB_NOUNS.fetch(tab)

  def filtered? = query.present? || within.present? || chosen.any? { |group, keys| group == "status" ? keys != [ DEFAULT_STATUS ] : keys.any? }

  private
    # Each model's ids in this tab and search.
    def base
      @base ||= (within && tab == "all" ? EVERYTHING : TABS.fetch(tab)).call
        .to_h { |type, scope| [ type, sourced(type, search(type, scope)).pluck(:id).to_set ] }
    end

    # The base, narrowed by every chosen group except one (nil: all of them).
    def filtered(except_group)
      base.to_h do |type, ids|
        narrowed = chosen.reduce(ids) do |set, (group, keys)|
          next set if group == except_group || keys.empty?

          set & keys.map { |key| tag_ids(Directory::Checks.find(key), type) }.reduce(:|)
        end
        [ type, narrowed ]
      end
    end

    def tag_ids(tag, type)
      @tag_ids ||= {}
      @tag_ids[[ tag.key, type ]] ||= self.class.tag_ids(tag, type)
    end

    # Only what a Sources row's or document's sources back (within).
    def sourced(type, scope)
      return scope unless within

      scope.where(id: Evidence.where(subject_type: type, source_id: SourceCatalog.source_ids(within)).select(:subject_id))
    end

    def search(type, scope)
      return scope unless query

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      case type
      when "Organization" then scope.where("organizations.name ILIKE ?", pattern)
      when "Facility" then scope.where("facilities.name ILIKE ?", pattern)
      when "Relationship"
        names = Organization.where("name ILIKE ?", pattern).select(:id)
        scope.where(from_organization_id: names).or(scope.where(to_organization_id: names))
      when "FacilityRelationship"
        scope.where(organization_id: Organization.where("name ILIKE ?", pattern).select(:id))
          .or(scope.where(facility_id: Facility.where("name ILIKE ?", pattern).select(:id)))
      end
    end

    FLAGGING = %w[flags gaps].freeze

    def rows_for(slice)
      records = slice.group_by(&:first).to_h do |type, pairs|
        model = type.constantize
        scope = model.where(id: pairs.map(&:last))
        scope = scope.includes(:from_organization, :to_organization) if model == Relationship
        scope = scope.includes(:organization, :facility) if model == FacilityRelationship
        [ type, scope.index_by(&:id) ]
      end
      flag_tags = FLAGGING.flat_map { |group| Directory::Checks.in_group(group) }
      slice.filter_map do |type, id|
        record = records.dig(type, id) or next
        flags = flag_tags.select { |tag| tag.applies_to?(type.constantize) && tag_ids(tag, type).include?(id) }.map(&:label)
        Row.new(type:, id:, name: name_of(record), kind: kind_of(record), status: status_of(type, record), flags:, changed_at: record.updated_at)
      end
    end

    def name_of(record)
      case record
      when Relationship then "#{record.from_organization.name} #{verb(record.relationship_type)} #{record.to_organization.name}"
      when FacilityRelationship then "#{record.organization.name} #{verb(record.relationship_type)} #{record.facility.name}"
      else record.name
      end
    end

    def verb(type) = DataQuality::Claim::RELATIONSHIP_VERBS.fetch(type.to_s, type.to_s.humanize(capitalize: false))

    def kind_of(record)
      case record
      when Organization then "Company"
      when Facility then record.parent_id.nil? && tab != "reactors" ? "Plant" : "Reactor"
      when Relationship then "Deal"
      else "Plant link"
      end
    end

    # The record's status in a word, "Live" unless otherwise.
    def status_of(type, record)
      return "Live" if tag_ids(Directory::Checks.find("live"), type).include?(record.id)
      return "Removed · merged" if tag_ids(Directory::Checks.find("merged"), type).include?(record.id)

      { "verified" => "Hidden", "pending" => "Pending", "rejected" => "Rejected", "unpublished" => "Removed" }.fetch(record.verification_status)
    end
end
