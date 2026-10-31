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
  # A seed or a bulk approval can approve dozens of one kind of fact in a day
  # (Data Quality, 31 Oct): at most this many of one kind per day.
  PER_KIND_PER_DAY = 5
  DEAL_WORDS = { "award" => "Award", "offtake" => "Power deal", "funding_round" => "Funding round", "loan" => "Loan" }.freeze

  BATCH = 200
  # What each kind's sentence reads, loaded with it.
  INCLUDES = {
    "Facility" => :parent, "Relationship" => %i[from_organization to_organization], "FacilityRelationship" => [ :organization, { facility: :parent } ],
    "OrganizationRole" => %i[organization role], "OrganizationTechnology" => %i[organization technology],
    "DealTerm" => :link, "LicensingStage" => [ :organization, { facility: :parent } ], "NewsItem" => { news_mentions: :subject }
  }.freeze

  # Each fact once: the first time a person approved it. Read newest first in
  # batches until enough published ones are found, and stop there.
  def entries(limit: 50, batch: BATCH)
    firsts = VerificationEvent.where(subject_type: KINDS, to_status: "verified").where("verification_events.by LIKE 'human:%'")
      .select("DISTINCT ON (subject_type, subject_id) subject_type, subject_id, created_at")
      .order(Arel.sql("subject_type, subject_id, created_at"))
    ordered = VerificationEvent.from(firsts, :verification_events).order(created_at: :desc, subject_type: :desc, subject_id: :desc)
    seen = Hash.new(0)
    found = []
    offset = 0
    while found.size < limit
      rows = ordered.offset(offset).limit(batch).pluck(:subject_type, :subject_id, :created_at)
      break if rows.empty?

      offset += rows.size
      records = published(rows)
      rows.each do |type, id, at|
        record = records[type][id] or next
        group = [ at.to_date, type, record.try(:relationship_type) || record.try(:term_type) ]
        next if (seen[group] += 1) > PER_KIND_PER_DAY

        (made = entry(record, at)) and found << made
        break if found.size >= limit
      end
    end
    found
  end

  private

  # This batch's records that are public now, with what their sentences read, and their sources.
  def published(rows)
    rows.group_by(&:first).to_h do |type, of_type|
      model = type.constantize
      records = model.published.where(id: of_type.map(&:second)).includes(INCLUDES[type] || []).to_a
      sources.merge!(Evidence.joins(:source).where(subject_type: type, subject_id: records.map(&:id)).order(:id)
        .pluck(:subject_id, "sources.url").reverse.to_h { |id, url| [ [ type, id ], url ] })
      [ type, records.index_by(&:id) ]
    end
  end

  def sources = (@sources ||= {})
  def public_companies = (@public_companies ||= Organization.published.pluck(:id).to_set)
  def public_plants = (@public_plants ||= Facility.published.pluck(:id).to_set)

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
      [ "#{record.organization.name} is now listed under #{DirectoryHelper::ROLE_LABELS.fetch(record.role.key, record.role.name)}", nil, company(record.organization) ]
    when OrganizationTechnology
      [ "#{record.organization.name} is now listed under #{record.technology.name}", nil, company(record.organization) ]
    when DealTerm then deal(record)
    when LicensingStage
      on = record.facility ? record.facility.parent || record.facility : record.organization
      [ "#{(record.facility || record.organization).name}: #{record.stage_label}", nil, on.is_a?(Facility) ? plant(on) : company(on) ]
    when NewsItem
      # A public page it mentions: a company first, else a plant.
      mention = record.news_mentions.select { |m| m.subject_type == "Organization" ? public_companies.include?(m.subject_id) : public_plants.include?(m.subject&.parent_id || m.subject_id) }
        .min_by { |m| [ m.subject_type == "Organization" ? 0 : 1, m.id ] }
      on = mention&.subject
      on = on.parent || on if on.is_a?(Facility)
      [ record.display_title, record.summary, on.is_a?(Facility) ? plant(on) : (company(on) if on) ]
    end
  end

  def deal(term)
    # The amount and date tell one award from another (Data Quality, 31 Oct).
    # A deal says its form and stage, as its row does (docs/DATA.md section 2): an MOU is not a signed PPA.
    details = [ (AdminHelper::AGREEMENT_LABELS.fetch(term.agreement, term.agreement.humanize) if term.agreement), (term.status if term.status && term.agreement),
      (usd(term.amount_usd) if term.amount_usd), (term.signed_on || term.starts_on)&.strftime("%b %Y") ].compact
    word = DEAL_WORDS.fetch(term.term_type, term.term_type.humanize)
    word = "#{word} (#{details.join(', ')})" if details.any?
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

  def company(organization) = ([ :company, organization.slug ] if organization&.slug && public_companies.include?(organization.id))
  def plant(facility) = ([ :plant, facility.slug ] if facility&.slug && public_plants.include?(facility.id))

  def usd(amount)
    amount = amount.to_d
    if amount >= 1_000_000_000 then "$#{format('%g', (amount / 1_000_000_000).round(1))} billion"
    elsif amount >= 1_000_000 then "$#{format('%g', (amount / 1_000_000).round(1))} million"
    else "$#{amount.round.to_i.to_fs(:delimited)}"
    end
  end

  # The first source behind it (loaded with its batch).
  def source_of(record) = sources[[ record.class.name, record.id ]]
end
