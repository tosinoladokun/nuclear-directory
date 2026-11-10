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
  # Finds a day at most, nightly and added ones together, so a pasted list can't use up the search quota (Infra).
  PER_DAY = 60
  WAITING = "Waiting: today's finds are used up; tried tonight".freeze

  # Counts one find against today's limit; false when it's reached.
  def self.take_today(now: Time.current)
    key = "lead_find/#{now.to_date.iso8601}"
    Rails.cache.increment(key, 1, expires_in: 2.days, initial: 0).to_i <= PER_DAY
  end
  FINDING = "Finding it".freeze
  UNCONFIRMED = "Couldn't confirm".freeze

  # Leads due a find: waiting ones, and ones whose weekly retry has come. Oldest first.
  def self.due(now: Time.current)
    Lead.where(kind: "company").where(status: "new")
      .or(Lead.where(kind: "company", status: "researching").where(next_find_at: ..now))
      .order(Arel.sql("COALESCE(leads.next_find_at, leads.updated_at)"))
  end

  # Marks the lead as being found, under its row lock, if it's still due; returns the attempt (the moment it
  # started, kept in next_find_at's place until the outcome), or nil. A find that never reports back (a restart)
  # is due again the next day.
  def self.start(lead, now: Time.current)
    lead.with_lock do
      next unless due(now:).exists?(id: lead.id)

      lead.update!(status: "researching", note: FINDING, next_find_at: now + 1.day)
      lead.reload.next_find_at # as stored (microseconds), to compare with later
    end
  end

  # Where a lead is, in one word for the admin (PM, 10 Nov): Finding, Waiting for check, In your inbox, Created,
  # Said no, Already listed, Couldn't confirm.
  SAID_NO = "Said no".freeze
  CLOSED = "Closed at check".freeze

  # Its claim was rejected: by a person (Said no) or at Data Quality's check, with its reason.
  def self.closed_at_check(lead, claim)
    by_person = claim.reviewed_by.to_s.start_with?("human:")
    why = (claim.dq_reason.presence || claim.notes.to_s.lines.last.to_s.squish.presence || "no reason given").truncate(300)
    reason = by_person ? SAID_NO : "#{CLOSED}: #{why}"
    lead.update!(status: "ignored", reason:, note: reason, next_find_at: nil,
      decided_by: claim.reviewed_by.presence || "agent:dq", decided_at: claim.reviewed_at || Time.current)
  end

  def self.state(lead)
    note = lead.note.to_s
    return SAID_NO if lead.status_ignored? && lead.reason == SAID_NO
    return note if lead.status_ignored? && note.start_with?(CLOSED)
    return "Couldn't confirm" if note.start_with?(UNCONFIRMED) || lead.status_ignored?
    return "Already listed" if lead.status_added? && lead.record_id && lead.candidate_id.nil?
    return "Finding" unless lead.status_added?

    claim = lead.candidate or return "Waiting for check"
    case claim.status
    when "merged" then "Created"
    when "rejected" then "Said no"
    else %w[new_record new_fact change].include?(DataQuality::Review.inbox_kind(claim)) ? "In your inbox" : "Waiting for check"
    end
  end

  # Writes the finder's outcome onto the lead.
  #   outcome: :proposed, :duplicate or :unconfirmed (anything else counts as unconfirmed)
  # attempt: what start returned. The outcome is written only while that attempt is still the lead's current one
  # (checked under its row lock): a person's decision, or a newer attempt, made meanwhile wins. Returns whether
  # it was written.
  def self.record(lead, attempt: nil, outcome:, organization_id: nil, candidate_id: nil, reason: nil, name: nil, website: nil, now: Time.current)
    lead.with_lock do
      current = attempt.nil? || (lead.status_researching? && lead.note == FINDING && lead.next_find_at == attempt)
      next false unless current

      write(lead, outcome:, organization_id:, candidate_id:, reason:, name:, website:, now:)
      true
    end
  end

  def self.write(lead, outcome:, organization_id:, candidate_id:, reason:, name:, website:, now:)
    case outcome.to_s
    when "proposed"
      lead.update!(status: "added", note: nil, next_find_at: nil, candidate_id:)
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
