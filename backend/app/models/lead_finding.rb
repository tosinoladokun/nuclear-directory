# One lead pipeline (#752, Tosin 10 Nov): every lead, from any source (a
# press release, NRC, USAspending, ARPA-E, or Tosin's "Suggest a company"),
# goes the same way: find its website, check it's the same company, in the
# US, doing nuclear work, fill it in, and propose it for his Create. Crawl's
# finder (DataQuality::LeadFinder) does that; this keeps the lead's state.
#
#   new          waiting (out of triage)
#   researching  being found, or waiting for its weekly retry (next_find_at)
#   added        proposed as a new company, or already listed (record set)
#   ignored      couldn't confirm after a month of weekly tries
module LeadFinding
  RETRY_AFTER = 1.week
  TRIES = 4 # weekly for a month
  PER_NIGHT = 20
  FINDING = "Finding it".freeze
  UNCONFIRMED = "Couldn't confirm".freeze

  # Leads due a find: waiting ones, and ones whose weekly retry has come. Oldest first.
  def self.due(now: Time.current)
    Lead.where(kind: "company").where(status: "new")
      .or(Lead.where(kind: "company", status: "researching").where(next_find_at: ..now))
      .order(Arel.sql("COALESCE(leads.next_find_at, leads.updated_at)"))
  end

  # A find that never reports back (a restart) is due again the next day.
  def self.start(lead, now: Time.current) = lead.update!(status: "researching", note: FINDING, next_find_at: now + 1.day)

  # Writes the finder's outcome onto the lead.
  #   outcome: :proposed, :duplicate or :unconfirmed (anything else counts as unconfirmed)
  def self.record(lead, outcome:, organization_id: nil, reason: nil, name: nil, website: nil, now: Time.current)
    case outcome.to_s
    when "proposed"
      lead.update!(status: "added", note: nil, next_find_at: nil)
    when "duplicate"
      lead.update!(status: "added", note: "Already listed", next_find_at: nil,
        record_type: ("Organization" if organization_id), record_id: organization_id)
    else
      tries = lead.find_attempts + 1
      found = [ name, website ].compact_blank.join(", ").presence
      note = [ UNCONFIRMED, reason.presence, ("found #{found}" if found) ].compact.join(": ")
      if tries >= TRIES
        lead.update!(status: "ignored", reason: "#{note} (tried #{tries} times over a month)", note:, find_attempts: tries, next_find_at: nil,
          decided_by: lead.decided_by || "agent:lead_finder", decided_at: now)
      else
        lead.update!(status: "researching", note:, find_attempts: tries, next_find_at: now + RETRY_AFTER)
      end
    end
  end
end
