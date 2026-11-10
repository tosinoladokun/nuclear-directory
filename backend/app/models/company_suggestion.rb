# "Suggest a company" on Tosin's inbox (#752): he types a name, a website or
# any link; Crawl's finder (DataQuality::CompanySuggestion) finds the website,
# checks it's a US company in nuclear, dedupes, and proposes the new company
# for his Create. Each suggestion is kept as a Lead (kind company), so it has
# a record and shows on the inbox while it's found, and if it couldn't be
# confirmed or is already listed.
#
#   CompanySuggestion.suggest("Kairos Power", by: "human:tosin") # => Lead, job queued
module CompanySuggestion
  KEY = "admin:suggest".freeze
  LABEL = "Suggested in the admin".freeze
  FINDING = "Finding it".freeze
  UNCONFIRMED = "Couldn't confirm".freeze
  MAX = 500
  SHOWN_FOR = 14.days

  def self.suggest(input, by:)
    text = input.to_s.squish
    return if text.blank? || text.length > MAX

    url = text if text.match?(%r{\Ahttps?://\S+\z}i)
    name = url ? (URI.parse(url).host.to_s.delete_prefix("www.") rescue text) : text
    lead = Lead.sighted!(name:, kind: "company", key: "#{KEY}:#{Lead.normalize(text)}", label: LABEL, url:) or return
    lead.update!(status: "researching", note: FINDING, decided_by: by, decided_at: Time.current, reason: nil, record_type: nil, record_id: nil)
    CompanySuggestionJob.perform_later(lead.id, text)
    lead
  end

  # The admin's suggestions of the last two weeks that are still being found,
  # couldn't be confirmed, or turned out to be listed already (a proposed one
  # is a Create in the inbox instead).
  def self.shown
    Lead.where(kind: "company", status: %w[researching added], updated_at: SHOWN_FOR.ago..)
      .where("leads.sources @> ?", [ { "label" => LABEL } ].to_json).where.not(note: nil).order(updated_at: :desc)
  end

  # Writes the finder's outcome onto the suggestion's Lead.
  #   outcome: :proposed, :duplicate or :unconfirmed (anything else is unconfirmed)
  def self.record(lead, outcome:, organization_id: nil, reason: nil, name: nil, website: nil)
    found = [ name, website ].compact_blank.join(", ").presence
    case outcome.to_s
    when "proposed"
      lead.update!(status: "added", note: nil)
    when "duplicate"
      lead.update!(status: "added", note: "Already listed", record_type: ("Organization" if organization_id), record_id: organization_id)
    else
      lead.update!(status: "researching", note: [ UNCONFIRMED, reason.presence, ("found #{found}" if found) ].compact.join(": "))
    end
  end
end
