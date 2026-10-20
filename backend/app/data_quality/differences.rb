# Where a candidate disagrees with a value a human verified on its record.
# Verify sends such candidates to review; the admin shows both values before
# a human approves one (approving applies the source's value).
#
#   DataQuality::Differences.with_human_verified(candidate, record)
#   # => { "state" => ["NJ", "DE"] }   # [verified, this source]
module DataQuality::Differences
  # Compared per kind. Names aren't: spelling and legal-form variants are
  # expected, and aliases cover them.
  COMPARED = {
    "organization" => %w[domain],
    "facility" => %w[nrc_docket eia_plant_id facility_type status state country_code],
    # A link's type and ends say which link it is; these are its details.
    "relationship" => %w[description started_on ended_on],
    "facility_relationship" => %w[ownership_pct description started_on ended_on]
  }.freeze

  # Values stored by key whose history is recorded under their column
  # (FactWriter writes the row it looks up: a facility's technology is
  # recorded as technology_id).
  AUDITED_AS = { "technology" => "technology_id", "role" => "role_id" }.freeze

  # record: a DirectoryClient::Record (or nil). Only a record a human
  # verified counts; anything else has no human value to protect.
  def self.with_human_verified(candidate, record)
    return {} unless record && record.verification_status == "verified" && record.verified_by.to_s.start_with?("human:")

    COMPARED.fetch(candidate.kind, []).each_with_object({}) do |name, differences|
      stored = comparable(name, record.values ? record.values[name] : record.public_send(name))
      incoming = comparable(name, incoming_value(candidate, name))
      next if stored.blank? || incoming.blank? || stored == incoming

      differences[name] = [ stored, incoming ]
    end
  end

  # The differences, unless every value the candidate would change is one
  # the pipeline wrote from the candidate's own kind of source: then {}
  # (Data Quality, 17 Oct). Every field approval would write counts, not
  # only the compared ones: coordinates, a company's description, and a
  # clear (a key with no value) too, so a value a person set or cleared
  # stays theirs. A field it can't compare keeps the conflict. A field counts as the pipeline's
  # when the latest event that changed it is an approval of a candidate
  # from the same kind of source, not edited first. Any other writer makes
  # it a person's: a seed, an admin edit, a repair, a merge, an edited
  # approval, another source. A blank no one ever wrote is no one's. One
  # person's field keeps them all, so a mixed claim stays a conflict.
  def self.written_by_person(differences, candidate, record, directory:)
    return differences if differences.empty?

    # A difference may be in a field the payload names another way (a
    # domain from a website), so the differences count too.
    pipeline_written?(candidate, record, directory:, also: differences.transform_values(&:first)) ? {} : differences
  end

  # Whether every field approving the candidate would change was last
  # written by the pipeline from its own kind of source (the rule above).
  # also: more fields to count, { name => stored value }.
  def self.pipeline_written?(candidate, record, directory:, also: {})
    fields = changing(candidate, directory.fact(type: record.type, id: record.id)&.values) or return false
    # Newest first, so find gives each field's latest write.
    history = directory.verification_history(type: record.type, id: record.id)
    evidence = directory.evidence(type: record.type, id: record.id)
    also.merge(fields).all? do |name, stored|
      column = AUDITED_AS.fetch(name, name)
      index = history.index { |event| event.changed_values.to_h.key?(column) }
      index ? pipeline_write?(history[index], history.first(index), candidate, evidence) : stored.blank?
    end
  end

  # What approving the candidate would change on its record:
  # { name => [stored, incoming] }, or nil when a field can't be compared.
  def self.changes(candidate, record, directory:)
    fields = changing(candidate, directory.fact(type: record.type, id: record.id)&.values) or return
    fields.to_h { |name, stored| [ name, [ stored, candidate.payload[name] ] ] }
  end

  # Each field approving the candidate would change: { name => stored value },
  # from every key DirectoryClient#write_fact writes. A key left out isn't
  # written; a key with no value clears the field. A matched record keeps
  # its name, and aliases are only ever added. nil when a field can't be
  # compared (it isn't one the record stores).
  def self.changing(candidate, stored)
    return unless stored

    written = candidate.payload.except(*DataQuality::DirectoryClient::WRITE_SKIPPED, "name", "aliases")
    written.each_with_object({}) do |(name, incoming), fields|
      return unless stored.key?(name)
      next if same?(name, stored[name], incoming)

      fields[name] = stored[name]
    end
  end

  # Numbers compare as numbers (40.123 is 40.123000), the rest as compared above.
  def self.same?(name, stored, incoming)
    if stored.is_a?(Numeric) && (number = BigDecimal(incoming.to_s, exception: false))
      return BigDecimal(stored.to_s) == number
    end

    comparable(name, stored) == comparable(name, incoming)
  end

  # An unedited approval of a claim from the candidate's kind of source.
  # Approvals record whether they were edited; older ones are told by their
  # evidence, and only when it can still be read as theirs: it has a
  # confidence (an edited approval stored none) and their run, and no later
  # approval used the same source and quote (it would have replaced both).
  def self.pipeline_write?(event, newer, candidate, evidence)
    context = event.context.to_h
    writer = context["candidate_id"] && Candidate.includes(:source).find_by(id: context["candidate_id"])
    return false unless writer && writer.source.source_kind == candidate.source.source_kind
    return context["edited"] == false if context.key?("edited")

    row = evidence.find { |item| item.source_id == writer.source_id && item.quote == writer.quote }
    return false unless row&.confidence && context["crawl_run_id"] && row.crawl_run_id == context["crawl_run_id"]

    later = newer.filter_map { |e| e.context.to_h["candidate_id"] }
    Candidate.where(id: later, source_id: writer.source_id, quote: writer.quote).none?
  end

  # "human-verified state is NJ; this source says DE"
  def self.describe(differences)
    differences.map do |name, (stored, incoming)|
      "human-verified #{DataQuality::Claim::LABELS.fetch(name) { name.humanize(capitalize: false) }} is #{stored}; this source says #{incoming}"
    end
      .join("; ")
  end

  # An organization's domain may arrive as domain or only as website.
  def self.incoming_value(candidate, name)
    name == "domain" ? candidate.payload["domain"].presence || candidate.payload["website"] : candidate.payload[name]
  end

  # Values compare as the directory stores them: text stripped, country
  # codes upcased, domains as hosts ("https://WWW.TerraPower.com/news" is
  # "terrapower.com"), percentages as numbers (40 is 40.0).
  def self.comparable(name, value)
    if name == "ownership_pct" && (number = BigDecimal(value.to_s, exception: false))
      return number.to_s("F").delete_suffix(".0")
    end
    return value.to_s.strip.upcase if name == "country_code"
    return value.to_s.strip unless name == "domain" && value.present?

    text = value.to_s.strip
    host = URI.parse(text.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? text : "https://#{text}").host
    host.to_s.downcase.delete_prefix("www.")
  rescue URI::InvalidURIError
    text.downcase.delete_prefix("www.")
  end
  private_class_method :changing, :same?, :pipeline_write?, :incoming_value, :comparable
end
