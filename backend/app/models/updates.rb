# What's new (PM, 31 Oct): facts, deals and news a person approved, newest
# first, for the public /updates page and its Atom feed, so analysts and
# reporters can follow the directory. Each entry is a public fact as it reads
# on its page, with the page it's on and the source behind it. Nothing
# internal: no reviewer, reason or pending claim.
#
#   Updates.new.entries(limit: 50) # => [Updates::Entry, …]
class Updates
  Entry = Data.define(:key, :kind, :title, :summary, :page, :source_url, :at)
  # page: [:company or :plant, slug]

  KINDS = %w[Organization Facility Relationship FacilityRelationship OrganizationRole OrganizationTechnology DealTerm LicensingStage NewsItem].freeze
  DEAL_WORDS = { "award" => "Award", "offtake" => "Power deal", "funding_round" => "Funding round", "loan" => "Loan" }.freeze

  # Each fact once: the first time a person approved it.
  def entries(limit: 50)
    firsts = VerificationEvent.where(subject_type: KINDS, to_status: "verified").where("verification_events.by LIKE 'human:%'")
      .select("DISTINCT ON (subject_type, subject_id) subject_type, subject_id, created_at")
      .order(Arel.sql("subject_type, subject_id, created_at"))
    rows = VerificationEvent.from(firsts, :verification_events).order(created_at: :desc, subject_id: :desc)
      .limit(limit * 4).pluck(:subject_type, :subject_id, :created_at)

    records = rows.group_by(&:first).to_h do |type, of_type|
      model = type.constantize
      [ type, model.published.where(id: of_type.map(&:second)).index_by(&:id) ]
    end
    rows.filter_map { |type, id, at| (record = records[type][id]) && entry(record, at) }.first(limit)
  end

  private

  def entry(record, at)
    title, summary, page = describe(record)
    return unless title && page

    Entry.new(key: "#{record.class.name.underscore}-#{record.id}", kind: kind_of(record), title:, summary:, page:,
      source_url: record.is_a?(NewsItem) ? record.url : source_of(record), at:)
  end

  def kind_of(record)
    case record
    when NewsItem then "news"
    when DealTerm then "deal"
    when Organization, Facility then "new_record"
    else "fact"
    end
  end

  def describe(record)
    case record
    when Organization then [ "New company: #{record.name}", record.short_description, company(record) ]
    when Facility
      site = record.parent || record
      [ record.parent ? "New unit: #{record.name} at #{site.name}" : "New plant: #{record.name}", nil, plant(site) ]
    when Relationship
      [ "#{record.from_organization.name} #{DirectoryHelper::RELATIONSHIP_VERBS.fetch(record.relationship_type)} #{record.to_organization.name}",
        record.description, company(record.from_organization) ]
    when FacilityRelationship
      [ "#{record.organization.name} #{DirectoryHelper::FACILITY_RELATIONSHIP_VERBS.fetch(record.relationship_type)} #{record.facility.name}",
        record.description, plant(record.facility.parent || record.facility) ]
    when OrganizationRole
      [ "#{record.organization.name}: #{DirectoryHelper::ROLE_LABELS.fetch(record.role.key, record.role.name)}", nil, company(record.organization) ]
    when OrganizationTechnology
      [ "#{record.organization.name}: #{record.technology.name}", nil, company(record.organization) ]
    when DealTerm then deal(record)
    when LicensingStage
      on = record.facility ? record.facility.parent || record.facility : record.organization
      [ "#{(record.facility || record.organization).name}: #{record.stage_label}", nil, on.is_a?(Facility) ? plant(on) : company(on) ]
    when NewsItem
      mention = record.news_mentions.min_by { |m| [ m.subject_type == "Organization" ? 0 : 1, m.id ] }
      on = mention&.subject
      on = on.parent || on if on.is_a?(Facility)
      [ record.display_title, record.summary, on.is_a?(Facility) ? plant(on) : (company(on) if on) ]
    end
  end

  def deal(term)
    word = DEAL_WORDS.fetch(term.term_type, term.term_type.humanize)
    case (link = term.link)
    when Organization then [ "#{word}: #{link.name}", nil, company(link) ]
    when Relationship
      [ "#{word}: #{link.from_organization.name} #{DirectoryHelper::RELATIONSHIP_VERBS.fetch(link.relationship_type)} #{link.to_organization.name}",
        nil, company(link.to_organization) ]
    when FacilityRelationship
      [ "#{word}: #{link.organization.name} #{DirectoryHelper::FACILITY_RELATIONSHIP_VERBS.fetch(link.relationship_type)} #{link.facility.name}",
        nil, plant(link.facility.parent || link.facility) ]
    end
  end

  def company(organization) = ([ :company, organization.slug ] if organization&.slug && Organization.published.exists?(organization.id))
  def plant(facility) = ([ :plant, facility.slug ] if facility&.slug && Facility.published.exists?(facility.id))

  def source_of(record) = record.evidence.joins(:source).order(:id).pick("sources.url")
end
