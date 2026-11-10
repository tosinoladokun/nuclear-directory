# One quote per field on a new-company claim (#760, lead pipeline). A
# company's description and its headquarters usually come from different
# lines or pages, and every fact has its own source. A claim may carry them as
#
#   payload["evidence"] = [ { "fields" => ["hq_city", "hq_state"], "quote" => "…", "source_url" => "https://…" }, … ]
#
# Before matching, each entry becomes its own claim on the same company (from
# its own source, with its own quote, checked by the verifier against that
# source like any claim), linked by payload["field_of"]; the main claim keeps
# the name and any field no entry names. Tosin's Create takes them together
# (OwnerInbox), so a filled company is still one Create.
module DataQuality::FieldEvidence
  FIELDS = %w[website description short_description hq_city hq_state].freeze
  KEYS = %w[evidence field_of].freeze

  # Splits a new claim's evidence into its field claims. Returns nil, or why the claim needs a person instead.
  def self.split!(candidate)
    entries = candidate.payload["evidence"]
    return unless candidate.kind_organization? && entries.present?
    return "its evidence must be a list of { fields, quote, source_url }" unless entries.is_a?(Array) && entries.all?(Hash)

    payload = candidate.payload
    named = entries.flat_map { |entry| Array(entry["fields"]).map(&:to_s) }
    return "evidence names fields a company claim can't carry: #{(named - FIELDS).join(', ')}" if (named - FIELDS).any?
    return "evidence names a field twice: #{named.tally.select { |_, n| n > 1 }.keys.join(', ')}" if named.uniq.size < named.size
    return "evidence names a field the claim has no value for: #{(named - payload.keys).join(', ')}" if (named - payload.compact_blank.keys).any?
    if (entry = entries.find { |e| e["quote"].to_s.squish.blank? || e["source_url"].to_s.blank? })
      return "every evidence entry needs a quote and a source_url (#{Array(entry['fields']).join(', ')})"
    end

    Candidate.transaction do
      entries.each do |entry|
        fields = Array(entry["fields"]).map(&:to_s)
        source = DataQuality::Sources.find_or_create(url: entry["source_url"].to_s)
        raise ActiveRecord::Rollback unless source.ok?

        Candidate.create!(source_id: source.ref.id, kind: "organization", status: "new", quote: entry["quote"].to_s.squish,
          crawl_run_id: candidate.crawl_run_id,
          payload: { "name" => payload["name"], "field_of" => candidate.id, **payload.slice(*fields) },
          notes: "#{fields.join(', ')} of claim ##{candidate.id}, from its own source")
      end
      candidate.update!(payload: payload.except("evidence", *named))
    end
    candidate.payload.key?("evidence") ? "an evidence source_url couldn't be used" : nil
  end

  # The field claims of a claim, still open.
  def self.fields_of(candidate_ids) = Candidate.where("candidates.payload->>'field_of' IN (?)", Array(candidate_ids).map(&:to_s))
    .where(status: %w[new matched needs_review])
end
