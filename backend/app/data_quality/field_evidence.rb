# One quote per field on a new-company claim (#760, lead pipeline). A
# company's description and its headquarters usually come from different
# lines or pages, and every fact has its own source. A claim may carry them as
#
#   payload["evidence"] = [ { "fields" => ["hq_city", "hq_state"], "quote" => "…", "source_url" => "https://…" }, … ]
#
# Matching resolves the company with everything the claim says (website and
# all), then splits each entry into its own claim on that same company (its
# own source, quote and fields, linked by payload["field_of"]); the main claim
# keeps the name and any field no entry names. A field claim never finds a
# company on its own: it follows its claim's. Each is checked by the verifier
# against its own page, and goes with Tosin's Create only once it's checked
# (OwnerInbox), so a filled company is still one Create.
module DataQuality::FieldEvidence
  FIELDS = %w[website description short_description hq_city hq_state].freeze
  # Bookkeeping, never written and never described to the checker.
  KEYS = %w[evidence field_of].freeze
  WAITING = "Waiting for its company claim to find its company".freeze

  # Why a claim's evidence can't be split (it goes to a person), or nil.
  def self.problem(candidate)
    entries = candidate.payload["evidence"]
    return unless candidate.kind_organization? && entries.present?
    return "its evidence must be a list of { fields, quote, source_url }" unless entries.is_a?(Array) && entries.all?(Hash)

    payload = candidate.payload
    named = entries.flat_map { |entry| Array(entry["fields"]).map(&:to_s) }
    return "evidence names fields a company claim can't carry: #{(named - FIELDS).join(', ')}" if (named - FIELDS).any?
    return "evidence names a field twice: #{named.tally.select { |_, n| n > 1 }.keys.join(', ')}" if named.uniq.size < named.size
    return "evidence names a field the claim has no value for: #{(named - payload.compact_blank.keys).join(', ')}" if (named - payload.compact_blank.keys).any?
    if (entry = entries.find { |e| e["quote"].to_s.squish.blank? || e["source_url"].to_s.blank? })
      return "every evidence entry needs a quote and a source_url (#{Array(entry['fields']).join(', ')})"
    end

    nil
  end

  # Splits the claim's evidence into field claims and strips those fields from it. Returns nil, or why not.
  # The source of each must be a page we've read (its text is what the checker reads), else it waits for a person.
  # Returns the source kinds of the field claims too, so their checks can be queued: [why, kinds].
  def self.split!(candidate)
    if (why = problem(candidate)) then return [ why, [] ] end
    return [ nil, [] ] if candidate.payload["evidence"].blank?

    payload = candidate.payload
    kinds = []
    Candidate.transaction do
      payload["evidence"].each do |entry|
        fields = Array(entry["fields"]).map(&:to_s)
        source = DataQuality::Sources.find_or_create(url: entry["source_url"].to_s)
        unless source.ok? && Source.where(id: source.ref.id).where.not(content_text: [ nil, "" ]).exists?
          raise Abort, "the page for #{fields.join(', ')} (#{entry['source_url']}) hasn't been read yet; cite a page we've stored"
        end

        field = Candidate.create!(source_id: source.ref.id, kind: "organization", status: "needs_review", quote: entry["quote"].to_s.squish,
          crawl_run_id: candidate.crawl_run_id, payload: { "name" => payload["name"], "field_of" => candidate.id, **payload.slice(*fields) },
          notes: WAITING)
        kinds << Source.find(field.source_id).source_kind
      end
      candidate.update!(payload: payload.except("evidence", *payload["evidence"].flat_map { |e| Array(e["fields"]).map(&:to_s) }))
    end
    [ nil, kinds.uniq ]
  rescue Abort => e
    [ e.message, [] ]
  end

  class Abort < StandardError; end

  # Puts a claim's open field claims on the company it was attached to (matched, its subject), or back to
  # waiting when it has none. Returns their states before, for Undo: [{ id, status, subject_type, subject_id, notes }].
  def self.follow!(candidate)
    fields_of(candidate.id).lock.map do |field|
      before = { "id" => field.id, "status" => field.status, "subject_type" => field.subject_type, "subject_id" => field.subject_id, "notes" => field.notes }
      if candidate.status_rejected?
        field.update!(status: "rejected", notes: "Closed with claim ##{candidate.id}")
      elsif candidate.subject_id
        field.update!(status: "matched", subject_type: candidate.subject_type, subject_id: candidate.subject_id, proposed_subject: false,
          notes: "#{field.payload.slice(*FIELDS).keys.join(', ')} of claim ##{candidate.id}, from its own source",
          ai_recommendation: (field.ai_recommendation if field.subject_id == candidate.subject_id))
      else
        field.update!(status: "needs_review", subject_type: nil, subject_id: nil, notes: WAITING)
      end
      before
    end
  end

  # Puts field claims back as they were before (Undo), unless one was changed since.
  def self.restore!(befores)
    Array(befores).each do |before|
      field = Candidate.lock.find_by(id: before["id"]) or next
      next if field.reviewed_by.present? # a person decided it: it stays

      field.update!(status: before["status"], subject_type: before["subject_type"], subject_id: before["subject_id"], notes: before["notes"])
    end
  end

  # The field claims of these claims, still open.
  def self.fields_of(candidate_ids) = Candidate.where("candidates.payload->>'field_of' IN (?)", Array(candidate_ids).map(&:to_s))
    .where(status: %w[new matched needs_review])

  # A field claim that may go with its company's Create: on that company, checked by the verifier against its own
  # page (agreed), its quote still in that page, and not contradicted.
  def self.ready?(field, company_id)
    field.status_matched? && field.subject_id == company_id && field.ai_recommendation == "recommend_publish" &&
      !DataQuality::Review.contradicted?(field) && quote_in_source?(field)
  end

  def self.quote_in_source?(field)
    check = DataQuality::Review.in_source(field) || ->(quote) { field.source.content_text.to_s.include?(quote.to_s) }
    field.quote.present? && check.call(field.quote)
  end
end
