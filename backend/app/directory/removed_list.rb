# The admin's Removed list (#166): every company, plant and link that's
# off the site now (taken off, merged into another record, or rejected),
# newest first, each with the decision that removed it: the reason, who
# made it and when. A record put back since isn't listed.
#
#   list = Directory::RemovedList.new(tab: "merged")
#   list.total    # => 4
#   list.page(1)  # => [Directory::RemovedList::Row, …]
#   list.count("rejected") # => 12
class Directory::RemovedList
  MODELS = [ Organization, Facility, Relationship, FacilityRelationship ].freeze
  TABS = { "all" => "All", "taken_off" => "Taken off", "merged" => "Merged", "rejected" => "Rejected" }.freeze
  PAGE = 50

  # what: "Taken off", "Merged" or "Rejected". merged_into: [type, id, name]
  # of the record it was merged into. put_back?: Put back applies (taken
  # off, not merged: a merge's facts moved to the record kept).
  Row = Data.define(:type, :id, :name, :kind, :what, :reason, :by, :at, :merged_into) do
    def put_back? = what == "Taken off"
  end

  attr_reader :tab

  def initialize(tab: "all")
    @tab = TABS.key?(tab) ? tab : "all"
  end

  def total = count(tab)

  def count(key) = key == "all" ? events.size : events.count { |event| what(event) == TABS.fetch(key) }

  def page(number)
    shown = tab == "all" ? events : events.select { |event| what(event) == TABS.fetch(tab) }
    slice = shown.drop((number - 1) * PAGE).first(PAGE)
    records = slice.group_by(&:subject_type).to_h do |type, group|
      [ type, scope(type.constantize).where(id: group.map(&:subject_id)).index_by(&:id) ]
    end
    survivors = merged_into(slice)
    slice.filter_map do |event|
      record = records.dig(event.subject_type, event.subject_id) or next
      into = event.context.to_h["merged_into"]
      Row.new(type: event.subject_type, id: event.subject_id, name: name_of(record), kind: kind_of(record), what: what(event),
        reason: event.reason, by: event.by, at: event.created_at,
        merged_into: (into && [ into["type"], into["id"], survivors.dig(into["type"], into["id"]) ]))
    end
  end

  private
    # For each record off the site, the decision that put it there: its
    # latest event to its current status, newest first.
    def events
      @events ||= MODELS.flat_map do |model|
        off = model.where(verification_status: %w[unpublished rejected])
        VerificationEvent.where(subject_type: model.name, subject_id: off.select(:id))
          .joins("JOIN #{model.table_name} ON #{model.table_name}.id = verification_events.subject_id")
          # The move to that status, not a later edit that left it there.
          .where("verification_events.to_status = #{model.table_name}.verification_status")
          .where("verification_events.from_status IS DISTINCT FROM verification_events.to_status")
          .select("DISTINCT ON (verification_events.subject_id) verification_events.*")
          .order("verification_events.subject_id, verification_events.created_at DESC, verification_events.id DESC").to_a
      end.sort_by { |event| [ -event.created_at.to_f, -event.id ] }
    end

    def what(event)
      return "Rejected" if event.to_status == "rejected"

      event.context.to_h.key?("merged_into") ? "Merged" : "Taken off"
    end

    def scope(model)
      case model.name
      when "Relationship" then model.includes(:from_organization, :to_organization)
      when "FacilityRelationship" then model.includes(:organization, :facility)
      else model.all
      end
    end

    # { type => { id => name } } of the records merged into.
    def merged_into(events)
      events.filter_map { |event| event.context.to_h["merged_into"] }.group_by { |into| into["type"] }.to_h do |type, intos|
        model = type.safe_constantize
        [ type, model && [ Organization, Facility ].include?(model) ? model.where(id: intos.map { |into| into["id"] }).pluck(:id, :name).to_h : {} ]
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
      when Facility then record.parent_id.nil? ? "Plant" : "Reactor"
      when Relationship then "Deal"
      else "Plant link"
      end
    end
end
