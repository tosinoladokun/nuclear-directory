# Data Quality's matching actions (#548, option a): its agent settles a
# company claim that isn't attached to a record yet, so Tosin only sees what's
# new. Nothing here verifies or publishes: a new company is pending until his
# Create, a new name for a company he decided waits as a Change, and every
# action is recorded (DqAction) with its reason and can be undone.
#
#   DataQuality::Matching.apply([{ "id" => 12, "action" => "same_as", "target" => 40, "reason" => "…" }])
#   # => [{ id: 12, ok: true, error: nil, created_ids: [] }]
#
# same_as:       attach it to an existing company (target: its id or exact
#                name). A claim that only names it another way confirms with its
#                quote as evidence; add_alias: true keeps the name as a Change.
# new:           a pending company from the claim, for Tosin's Create / No.
# subsidiary_of: a pending company, plus a pending "subsidiary of" link to
#                the target, both for his decision.
# close:         reject any open, unattached claim (a company, link, deal term
#                or news item) with the reason; a lead's name stays in Leads.
module DataQuality::Matching
  BY = "agent:data-quality"
  OPEN = %w[new needs_review].freeze
  MAX_REASON = 1_000
  # A circuit breaker against a runaway agent (Infra): new companies a day,
  # undone ones included, so create, undo, create never resets it.
  DAILY_CREATES = 200
  # The same for closes (Infra): the widest action, undone ones included.
  DAILY_CLOSES = 300
  # And for verdicts recorded through recommend.
  DAILY_RECOMMENDS = 500
  DAILY_ROLES = 200
  # What Data Quality may fill on a published company (PM, 30 Oct: complete companies).
  # Plus a legal name and the country (PM, 18 Nov: Cameco is Canadian), as two capital letters.
  # Plus a public company's ticker and its exchange (#874; a 10-K or annual-report cover), always together: the table needs both or neither.
  # Plus the short name a chart or tight label shows ("TVA", "FPL"; #909), 30 characters at most, as the column allows.
  FIELDS = %w[website description short_description hq_city hq_state sec_cik legal_name country_code ticker exchange short_name].freeze
  MAX_SHORT_NAME = 30
  TICKER = /\A[A-Z0-9][A-Z0-9.\-]{0,7}\z/
  EXCHANGE = /\A[A-Za-z][A-Za-z .&-]{1,19}\z/
  # What a cover calls an exchange, besides its short name: the quote must name the ticker AND the exchange, so a ticker can't ride on an
  # unrelated quote.
  EXCHANGE_NAMES = { "NYSE" => /NYSE|New York Stock Exchange/i, "NASDAQ" => /Nasdaq/i, "TSX" => /TSX|Toronto Stock Exchange/i,
                     "NYSE American" => /NYSE American|NYSE MKT|American Stock Exchange/i, "LSE" => /LSE|London Stock Exchange/i,
                     "ASX" => /ASX|Australian Securities Exchange/i }.freeze
  # An SEC CIK is sourced to EDGAR only (PM, 31 Oct).
  EDGAR_HOSTS = %w[sec.gov www.sec.gov efts.sec.gov data.sec.gov].freeze
  MAX_DESCRIPTION = 2_000
  VERDICTS = %w[approve reject].freeze
  # Stops an action part-way: everything it wrote rolls back, and the message is the row's error.
  class Abort < StandardError; end

  Row = Data.define(:id, :ok, :error, :created_ids) do
    def to_h = { id:, ok:, error:, created_ids: }
  end

  def self.apply(rows, directory: DataQuality::DirectoryClient.new)
    # Each source matched again once per request, however many of its ends
    # were settled (Infra: verify is the AI step).
    requeue = Set.new
    rows = Array(rows).map { |row| row.to_h.stringify_keys }
    results = rows.map { |row| apply_one(row, directory, requeue) }
    # The pages new proposals cite are stored first, then match and verify
    # run, so a claim is checked against its page (#934).
    claims = rows.zip(results).select { |row, result| result.ok && PAGE_ACTIONS.include?(row["action"].to_s) }.flat_map { |_, result| result.created_ids }
    pages = DataQuality::ProposalPages.due(claims)
    if pages.any?
      DataQuality::ProposalPagesJob.perform_later(pages, requeue.to_a)
    else
      requeue.each { |kind| DataQuality::RunJob.perform_later(kind, only: %w[match verify]) }
    end
    results
  end

  def self.apply_one(row, directory, requeue = Set.new)
    return propose_operator_change(row, directory, requeue) if row["action"].to_s == "propose_operator_change"
    return propose_site_fields(row, directory, requeue) if row["action"].to_s == "propose_site_fields"
    return propose_role(row, directory, requeue) if PROPOSALS.include?(row["action"].to_s)

    id, action, reason = row["id"].to_i, row["action"].to_s, row["reason"].to_s.squish
    fail_with = ->(why) { Row.new(id:, ok: false, error: why, created_ids: []) }
    return fail_with.call("action must be one of #{DqAction::ACTIONS.join(', ')}") unless (DqAction::ACTIONS - PROPOSALS).include?(action)
    return fail_with.call("give a reason") if reason.blank?
    return fail_with.call("keep the reason under #{MAX_REASON} characters") if reason.length > MAX_REASON
    if %w[new subsidiary_of].include?(action) && DqAction.where(action: %w[new subsidiary_of], created_at: Time.current.all_day).count >= DAILY_CREATES
      return fail_with.call("today's limit of #{DAILY_CREATES} new companies is reached; ask Backend")
    end
    if action == "close" && DqAction.where(action: "close", created_at: Time.current.all_day).count >= DAILY_CLOSES
      return fail_with.call("today's limit of #{DAILY_CLOSES} closes is reached; ask Backend")
    end
    if action == "recommend"
      return fail_with.call("verdict must be approve or reject") unless VERDICTS.include?(row["verdict"].to_s)
      if DqAction.where(action: "recommend", created_at: Time.current.all_day).count >= DAILY_RECOMMENDS
        return fail_with.call("today's limit of #{DAILY_RECOMMENDS} verdicts is reached; ask Backend")
      end
    end

    key = row["request_key"].presence&.to_s
    Candidate.transaction do
      candidate = Candidate.lock.find_by(id:) or next fail_with.call("no claim ##{id}")
      # Sent again (the same key, or the same action already done): fine, nothing more happens.
      # A live action counts only while the claim is still as it left it
      # (a person may have reopened it since).
      # Settling an end is never taken for a retry of another (a claim has two
      # ends); only its request_key makes it one.
      done = (DqAction.find_by(request_key: key) if key) || (row["end"].blank? &&
        DqAction.live.where(candidate_id: id, action:).order(:id).last&.then { |last| last if left_as?(last, candidate) && same_verdict?(last, row) })
      next Row.new(id:, ok: true, error: nil, created_ids: ids_of(done.created)) if done
      # Close applies to any open claim (a link, a deal term, news); the
      # others settle a company, so they need a company claim.
      # same_as with an end settles that end of a link claim (#548): which
      # company or plant it names. Otherwise only close applies to a link.
      end_key = row["end"].presence&.to_s
      # A verdict on any waiting claim (attached or not), as the paste box records it.
      if action == "recommend"
        next Row.new(id:, ok: true, error: "skipped: it's already #{candidate.status}", created_ids: []) unless
          DataQuality::Recommendations::OPEN.include?(candidate.status)

        before = candidate.slice(*RECOMMEND_FIELDS).as_json
        candidate.update!(dq_recommendation: row["verdict"].to_s, dq_reason: reason, dq_by: BY, dq_at: Time.current,
          dq_payload_sha256: DataQuality::Recommendations.digest(candidate))
        DqAction.create!(candidate:, action:, reason:, before:, created: [], by: BY, request_key: key, after: stamp_of(candidate.reload))
        next Row.new(id:, ok: true, error: nil, created_ids: [])
      end
      if end_key
        next fail_with.call("an end goes with same_as") unless action == "same_as"
        next fail_with.call("#{end_key.inspect} isn't an end of a #{candidate.kind} claim") unless end_type(candidate, end_key)
      elsif !(candidate.kind == "organization" || action == "close" || (action == "new" && candidate.kind == "facility"))
        next fail_with.call("it isn't a company claim; only close applies to it (new also takes a plant claim; same_as takes an end)")
      end
      # No longer open (settled meanwhile): skipped, not an error (Infra).
      # "new" may also take a company claim out of a wrong match (DQ, 29 Oct):
      # attached to an existing record, still waiting, decided by no one.
      rematch = action == "new" && candidate.kind == "organization" && %w[matched needs_review].include?(candidate.status) &&
        candidate.subject_id && !candidate.proposed_subject && candidate.reviewed_by.nil?
      next Row.new(id:, ok: true, error: "skipped: it's already attached or decided (#{candidate.status})", created_ids: []) unless
        (OPEN.include?(candidate.status) && candidate.subject_id.nil?) || rematch

      before = candidate.slice(:status, :subject_type, :subject_id, :proposed_subject, :notes, :reviewed_by, :reviewed_at, :payload).as_json
      # A claim with one quote per field (#760) that never went through matching is split first.
      if candidate.kind == "organization" && candidate.payload["evidence"].present?
        why, = DataQuality::FieldEvidence.split!(candidate)
        raise Abort, why if why

        before["payload"] = candidate.payload.as_json # Undo keeps it split; its field claims go back to waiting
      end
      created = []
      record = nil
      if end_key
        record, error = target(row, directory, type: end_type(candidate, end_key) == :facility ? "Facility" : "Organization")
        raise Abort, error if error
      elsif %w[same_as subsidiary_of].include?(action)
        record, error = target(row, directory)
        raise Abort, error if error
      end
      error = case action
      when "same_as" then end_key ? settle_end(candidate, end_key, record, reason, requeue) : same_as(candidate, row, record, reason, directory, created)
      when "new" then propose(candidate, reason, directory, created)
      when "subsidiary_of" then subsidiary_of(candidate, record, reason, directory, created)
      when "close" then close(candidate, reason, directory)
      end
      raise Abort, error if error

      # Its field claims (#760) follow it to its company (or close with it); Undo puts them back.
      before["fields"] = DataQuality::FieldEvidence.follow!(candidate.reload) if candidate.kind == "organization"
      DqAction.create!(candidate:, action:, target_type: (record.type if record), target_id: record&.id, reason:, before:, created:,
        by: BY, request_key: key, after: stamp_of(candidate.reload))
      Row.new(id:, ok: true, error: nil, created_ids: ids_of(created))
    end
  rescue Abort => e
    Row.new(id: row["id"].to_i, ok: false, error: e.message, created_ids: [])
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    Row.new(id: row["id"].to_i, ok: false, error: "someone was deciding on it just then; try again", created_ids: [])
  end

  # Undo one action, while what it did is still as it left it. Returns an error or nil.
  def self.undo(action_id, directory: DataQuality::DirectoryClient.new)
    Candidate.transaction do
      action = DqAction.lock.find_by(id: action_id) or raise Abort, "no action ##{action_id}"
      raise Abort, "it was undone already" if action.undone_at

      candidate = Candidate.lock.find(action.candidate_id)
      if PROPOSALS.include?(action.action)
        undo_role(action, candidate, directory)
        next nil
      end
      raise Abort, "the claim was changed since (decided, reopened or moved by a merge), so it can't be undone here" unless left_as?(action, candidate)
      # The record it goes back to must still be open (merged away or taken off: no).
      if (type, id = action.before.values_at("subject_type", "subject_id")).all?
        directory.lock_fact(type:, id:)
        unless %w[verified pending].include?(directory.fact(type:, id:)&.verification_status)
          raise Abort, "the record it was on (#{type} ##{id}) was merged or taken off since, so it can't go back there"
        end
      end

      # What it created goes too, but only while it's still pending.
      action.created.each do |ref|
        if ref["type"] == "Evidence"
          result = directory.remove_evidence(type: ref["on"], id: ref["record_id"], evidence_id: ref["id"], source_id: ref["source_id"],
            quote: ref["quote"], by: BY, reason: "Data Quality undid same_as")
          raise Abort, "couldn't take back its quote: #{result.errors.to_sentence}" unless result.success?

          next
        end
        type, id = ref["type"], ref["id"]
        directory.lock_fact(type:, id:)
        decided = directory.fact(type:, id:)&.verification_status != "pending" || directory.verification_history(type:, id:).size != ref["events"]
        # Its own field claims (#760) aren't others: they go back with it.
        own_fields = Array(action.before["fields"]).map { |field| field["id"] }
        others = Candidate.where(subject_type: type, subject_id: id).where.not(id: [ ref["candidate_id"], *own_fields ]).where.not(status: "rejected").exists?
        raise Abort, "#{type} ##{id} was decided or claimed since, so it can't be undone here" if decided || others

        Candidate.find_by(id: ref["candidate_id"])&.update!(status: "rejected", reviewed_by: BY, reviewed_at: Time.current, notes: "Undone by Data Quality") if ref["link_claim"]
        errors = directory.decide_fact(ref["type"].underscore, id: ref["id"], status: "rejected", by: BY, reason: "Data Quality undid #{action.action}").errors
        raise Abort, errors.to_sentence if errors.any?
      end
      DataQuality::FieldEvidence.restore!(action.before["fields"])
      if action.action == "recommend"
        candidate.update!(action.before.slice(*RECOMMEND_FIELDS))
      else
        candidate.update!(action.before.slice("status", "subject_type", "subject_id", "proposed_subject", "notes", "reviewed_by", "reviewed_at", "payload"))
      end
      action.update!(undone_at: Time.current, undone_by: BY)
      nil
    end
  rescue Abort => e
    e.message
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    "someone was deciding on it just then; try again"
  end

  # Everything Recommendations.digest reads, so a changed claim is never taken for the same one.
  STAMPED = %w[status subject_type subject_id proposed_subject reviewed_by payload quote reopenings dq_recommendation dq_reason].freeze
  RECOMMEND_FIELDS = %w[dq_recommendation dq_reason dq_by dq_at dq_payload_sha256].freeze

  # The claim as an action left it, compared under its lock: anything since
  # (a decision, a reopen, a merge repointing it) means it isn't the same.
  def self.stamp_of(candidate) = candidate.slice(*STAMPED).as_json
  # Only the fields the action stamped (actions before payload was stamped keep working).
  # A verdict counts as a repeat only when it's the same verdict (Database).
  def self.same_verdict?(action, row) = action.action != "recommend" || action.after["dq_recommendation"] == row["verdict"].to_s

  def self.left_as?(action, candidate) = action.after.present? && stamp_of(candidate).slice(*action.after.keys) == action.after

  # propose_role (#548): Data Quality proposes a sourced role for a company,
  # as a claim with its quote and source, matched and verified like any
  # other and decided by Tosin. Nothing publishes here.
  #   { action: "propose_role", target: company id or slug, role: "reactor_vendor",
  #     quote: "…", source_url: "https://…", reason: "…" }
  # propose_fields (PM, 30 Oct): sourced values for a published company's
  # website, description, short description, HQ or SEC CIK (from an sec.gov
  # page only), as one company claim:
  #   { action: "propose_fields", target:, fields: { "hq_city" => "Austin", … }, quote:, source_url:, reason: }
  # It's matched to the company and shows as a Change (old → new) for Tosin.
  # propose_link (PM, 18 Nov): a sourced link between two companies, as a claim matched and decided like any other:
  # A company is its id, its slug, a former slug or its page's address (https://nuclear-directory.org/companies/oklo).
  #   { action: "propose_link", target: from company, other: to company, relationship_type: "invests_in",
  #     description: "49% stake", quote:, source_url:, reason: }
  def self.propose_role(row, directory, requeue)
    action = row["action"].to_s
    reason, quote, role = row["reason"].to_s.squish, row["quote"].to_s.squish, row["role"].to_s
    # Only an object of fields; a list or a string is refused below, never raised.
    fields = row["fields"].is_a?(Hash) ? row["fields"].transform_keys(&:to_s).transform_values { |value| value.to_s.squish } : {}
    fail_with = ->(why) { Row.new(id: nil, ok: false, error: why, created_ids: []) }
    return fail_with.call("give a reason") if reason.blank?
    return fail_with.call("keep the reason under #{MAX_REASON} characters") if reason.length > MAX_REASON
    return fail_with.call("give the quote that states it") if quote.blank?
    if action == "propose_role"
      return fail_with.call("#{role.inspect} isn't a role") unless directory.role_key?(role)
    elsif action == "propose_link"
      verbs = DataQuality::Review::COMPANY_LINK_VERBS.keys
      return fail_with.call("relationship_type must be one of #{verbs.join(', ')}") unless verbs.include?(row["relationship_type"].to_s)
      return fail_with.call("give the other company: its id or slug") if row["other"].blank?
      return fail_with.call("a description is #{MAX_DESCRIPTION} characters at most") if row["description"].to_s.length > MAX_DESCRIPTION
    else
      return fail_with.call("give fields: one or more of #{FIELDS.join(', ')}") if fields.empty?
      return fail_with.call("only #{FIELDS.join(', ')} can be proposed") unless (fields.keys - FIELDS).empty?
      return fail_with.call("give a value for every field") if fields.values.any?(&:blank?)
      return fail_with.call("a short description is #{ShortDescription::MAX} characters at most") if fields["short_description"].to_s.length > ShortDescription::MAX
      return fail_with.call("a description is #{MAX_DESCRIPTION} characters at most") if fields["description"].to_s.length > MAX_DESCRIPTION
      if fields.key?("short_name")
        return fail_with.call("a short name is #{MAX_SHORT_NAME} characters at most") if fields["short_name"].length > MAX_SHORT_NAME
        # The source must use the short name itself, as a whole word, so it can't ride on an unrelated quote.
        unless quote.match?(/(?<![[:alnum:]])#{Regexp.escape(fields['short_name'])}(?![[:alnum:]])/)
          return fail_with.call("the quote must contain the short name #{fields['short_name']}")
        end
      end
      # Only a website people can open (https with a host): never a javascript: or broken link (Infra).
      return fail_with.call("the website must be a full https:// address") if fields.key?("website") && !directory.readable_website?(fields["website"])
      return fail_with.call("a country is two capital letters (ISO 3166, e.g. CA)") if fields.key?("country_code") && !fields["country_code"].match?(/\A[A-Z]{2}\z/)
      return fail_with.call("a ticker and its exchange go together: give both") if fields.key?("ticker") != fields.key?("exchange")
      return fail_with.call("a ticker is capital letters or digits (e.g. NNE, BRK.B)") if fields.key?("ticker") && !fields["ticker"].match?(TICKER)
      return fail_with.call("an exchange is its short name (e.g. NYSE, NASDAQ, TSX)") if fields.key?("exchange") && !fields["exchange"].match?(EXCHANGE)
      if fields.key?("ticker")
        return fail_with.call("the quote must contain the ticker #{fields['ticker']}") unless quote.match?(/(?<![A-Za-z0-9.])#{Regexp.escape(fields['ticker'])}(?![A-Za-z0-9])/)

        named = EXCHANGE_NAMES.fetch(fields["exchange"], /#{Regexp.escape(fields['exchange'])}/i)
        return fail_with.call("the quote must name the exchange (#{fields['exchange']})") unless quote.match?(named)
      end
      if fields.key?("sec_cik")
        cik = directory.normalize_cik(fields["sec_cik"])
        return fail_with.call("an SEC CIK is up to 10 digits") unless cik.to_s.match?(/\A\d{10}\z/)
        return fail_with.call("an SEC CIK's source must be an sec.gov (EDGAR) page") unless EDGAR_HOSTS.include?((URI.parse(row["source_url"].to_s.strip).host rescue nil).to_s.downcase)
        fields["sec_cik"] = cik
      end
    end
    # A retry (same request_key) is answered first, whatever today's count.
    key = row["request_key"].presence&.to_s
    if key && (done = DqAction.find_by(request_key: key))
      return Row.new(id: done.candidate_id, ok: true, error: nil, created_ids: [ done.candidate_id ])
    end
    if DqAction.where(action:, created_at: Time.current.all_day).count >= DAILY_ROLES
      return fail_with.call("today's limit of #{DAILY_ROLES} is reached for #{action}; ask Backend")
    end

    Candidate.transaction do
      record, error = target(row, directory)
      raise Abort, error if error
      if fields["sec_cik"] && (holder = directory.organization(sec_cik: fields["sec_cik"])) && holder.id != record.id
        raise Abort, "CIK #{fields['sec_cik']} is already #{holder.name}'s (##{holder.id})"
      end

      source = DataQuality::Sources.find_or_create(url: row["source_url"].to_s)
      raise Abort, "the source: #{source.errors.to_sentence}" unless source.ok?

      kind, payload = if action == "propose_role"
        [ "organization_role", { "organization" => { "name" => record.name }, "role" => role } ]
      elsif action == "propose_link"
        other, error = target({ "target" => row["other"] }, directory)
        raise Abort, "other: #{error}" if error
        raise Abort, "a company can't be linked to itself" if other.id == record.id

        [ "relationship", { "from_organization" => { "name" => record.name }, "to_organization" => { "name" => other.name },
                            "relationship_type" => row["relationship_type"].to_s, "description" => row["description"].to_s.squish.presence }.compact ]
      else
        [ "organization", { "name" => record.name }.merge(fields) ]
      end
      claim = Candidate.create!(source_id: source.ref.id, kind:, status: "new", quote:, payload:, notes: "Data Quality proposed it: #{reason}")
      DqAction.create!(candidate: claim, action:, target_type: "Organization", target_id: record.id, reason:,
        before: {}, created: [], by: BY, request_key: key, after: stamp_of(claim))
      requeue << source.ref.source_kind
      Row.new(id: claim.id, ok: true, error: nil, created_ids: [ claim.id ])
    end
  rescue Abort => e
    Row.new(id: nil, ok: false, error: e.message, created_ids: [])
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # A concurrent retry with the same key won: its claim is the answer.
    won = key && DqAction.find_by(request_key: key)
    raise e unless won

    Row.new(id: won.candidate_id, ok: true, error: nil, created_ids: [ won.candidate_id ])
  end

  PROPOSALS = %w[propose_role propose_fields propose_link propose_site_fields].freeze
  # Actions whose created_ids are the claims they made, each citing a page.
  PAGE_ACTIONS = (PROPOSALS + %w[propose_operator_change]).freeze

  # propose_operator_change (#930): a plant's operator replaced, from a source that names the new one. Each claim is
  # Tosin's to decide on its own (Review::OPERATOR_CHANGE): the current "from operates plant" link gets ended_on: since
  # (a change on that link), and "to operates plant" is added with started_on: since.
  #   { action: "propose_operator_change", target: plant or unit (id, slug or page address), from: company, to: company,
  #     since: "2024-03-01", quote:, source_url:, since_quote: (optional), since_source_url: (optional), reason:, request_key: }
  # The quote names the new operator. The date is stated by the quote, or by since_quote, a second quote from its own
  # source (since_source_url, else source_url; PM, 25 Nov). With since_quote, each quote is its own claim, so each is
  # checked against its own source and becomes evidence: "to operates plant" (quote), the same link with started_on
  # (since_quote), and the old link's ended_on (since_quote, the quote that states when).
  # Recorded as propose_link actions on the plant (no new action kind); each claim can be undone.
  def self.propose_operator_change(row, directory, requeue)
    reason, quote = row["reason"].to_s.squish, row["quote"].to_s.squish
    fail_with = ->(why) { Row.new(id: nil, ok: false, error: why, created_ids: []) }
    return fail_with.call("give a reason") if reason.blank?
    return fail_with.call("keep the reason under #{MAX_REASON} characters") if reason.length > MAX_REASON
    return fail_with.call("give the quote that names the new operator") if quote.blank?
    since = (Date.iso8601(row["since"].to_s) rescue nil)
    return fail_with.call("since is the date the new operator took over, like 2024-03-01") unless since
    return fail_with.call("since can't be in the future") if since > Date.current
    since_quote = row["since_quote"].to_s.squish.presence
    if since_quote
      return fail_with.call("the since quote must state the date #{since.strftime('%-d %B %Y')}") unless date_stated?(since_quote, since)
    elsif !date_stated?(quote, since)
      return fail_with.call("the quote must state the date #{since.strftime('%-d %B %Y')}, or give it in since_quote with its source")
    end
    return fail_with.call("give from (the current operator) and to (the new one): an id or slug") if row["from"].blank? || row["to"].blank?

    key = row["request_key"].presence&.to_s
    # The claims' own keys are key, key:end and key:date, so a caller's key never ends in those (Copilot).
    return fail_with.call("a request_key can't end in :end or :date") if key&.match?(/:(?:end|date)\z/)
    done = key && operator_change_done(key)
    return done if done
    if DqAction.where(action: "propose_link", created_at: Time.current.all_day).count + (since_quote ? 3 : 2) > DAILY_ROLES
      return fail_with.call("today's limit of #{DAILY_ROLES} is reached for propose_link; ask Backend")
    end

    Candidate.transaction do
      found, error = target(row, directory, type: "Facility")
      raise Abort, error if error

      plant = directory.facility(id: found.id)
      from, error = target({ "target" => row["from"] }, directory)
      raise Abort, "from: #{error}" if error
      to, error = target({ "target" => row["to"] }, directory)
      raise Abort, "to: #{error}" if error
      raise Abort, "from and to are the same company" if from.id == to.id

      link = ->(company) { directory.existing_fact("facility_relationship", organization_id: company.id, facility_id: plant.id, relationship_type: "operates") }
      old = link.call(from)
      unless old && %w[verified pending].include?(old.verification_status) && old.values.to_h["ended_on"].blank?
        raise Abort, "#{from.name} has no current operates link to #{plant.name}"
      end
      raise Abort, "#{to.name} already has an operates link to #{plant.name} (#{link.call(to).decision}); ask Backend" if link.call(to)

      names = [ *directory.organization_names(to.id), directory.fact(type: "Organization", id: to.id)&.values.to_h["short_name"] ].compact_blank.uniq
      unless names.any? { |name| quote.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i) }
        raise Abort, "the quote must name the new operator (#{names.join(' or ')})"
      end

      source = DataQuality::Sources.find_or_create(url: row["source_url"].to_s)
      raise Abort, "the source: #{source.errors.to_sentence}" unless source.ok?
      dated = since_quote ? DataQuality::Sources.find_or_create(url: (row["since_source_url"].presence || row["source_url"]).to_s) : source
      raise Abort, "the since source: #{dated.errors.to_sentence}" unless dated.ok?

      ends = ->(company) { { "organization" => { "name" => company.name }, "facility" => { "name" => plant.name }, "relationship_type" => "operates" } }
      note = "Data Quality proposed it: #{to.name} operates #{plant.name} from #{since.iso8601}, replacing #{from.name}. #{reason}"
      note += " Named by: \"#{quote.truncate(300)}\"" if since_quote
      claim = ->(on, text, payload) { Candidate.create!(source_id: on.ref.id, kind: "facility_relationship", status: "new", quote: text, notes: note, payload:) }
      # Without since_quote the quote states both; with it, the date goes on the claims its quote supports.
      added = claim.call(source, quote, since_quote ? ends.call(to) : ends.call(to).merge("started_on" => since.iso8601))
      ended = claim.call(dated, since_quote || quote, ends.call(from).merge("ended_on" => since.iso8601))
      started = claim.call(dated, since_quote, ends.call(to).merge("started_on" => since.iso8601)) if since_quote
      [ [ added, key ], [ ended, key && "#{key}:end" ], [ started, key && "#{key}:date" ] ].each do |made, request_key|
        next unless made

        DqAction.create!(candidate: made, action: "propose_link", target_type: "Facility", target_id: plant.id, reason:,
          before: {}, created: [], by: BY, request_key:, after: stamp_of(made))
      end
      requeue << source.ref.source_kind << dated.ref.source_kind
      Row.new(id: added.id, ok: true, error: nil, created_ids: [ added, ended, started ].compact.map(&:id))
    end
  rescue Abort => e
    Row.new(id: nil, ok: false, error: e.message, created_ids: [])
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    won = key && operator_change_done(key)
    raise e unless won

    won
  end

  # A retry of an operator change: its result when key is that change's own (its first claim's key), else nil.
  # Only the change that made key counts; another action holding the key is a conflict, never a success.
  def self.operator_change_done(key)
    first = DqAction.find_by(request_key: key) or return
    unless first.action == "propose_link" && first.target_type == "Facility"
      return Row.new(id: nil, ok: false, error: "request_key #{key.inspect} is another action's", created_ids: [])
    end

    ids = DqAction.where(request_key: [ key, "#{key}:end", "#{key}:date" ]).order(:id).pluck(:candidate_id)
    Row.new(id: first.candidate_id, ok: true, error: nil, created_ids: ids)
  end

  MONTHS = Date::MONTHNAMES.compact.freeze

  # Whether a quote states this date (#930): 2024-03-01, March 1, 2024 (or Mar. 1 / 1st), 1 March 2024; a date on the
  # 1st also as March 2024, as DATA.md stores a month-only date.
  def self.date_stated?(quote, date)
    month = "(?:#{Regexp.escape(MONTHS[date.month - 1])}|#{Regexp.escape(MONTHS[date.month - 1][0, 3])}\\.?)"
    day = "0?#{date.day}(?:st|nd|rd|th)?"
    forms = [ Regexp.escape(date.iso8601), "#{month}\\s+#{day},?\\s+#{date.year}", "#{day}\\s+#{month},?\\s+#{date.year}" ]
    # Month-only, never the tail of a full date ("11 March 2024" doesn't state 1 March).
    forms << "(?<!\\d\\s)(?<!\\d[a-z]{2}\\s)#{month},?\\s+#{date.year}" if date.day == 1
    quote.match?(/(?<![[:alnum:]])(?:#{forms.join('|')})(?![[:alnum:]])/i)
  end

  # propose_site_fields (#916): a published site's coordinates, as a pair, and its EIA plant ID, from a
  # source that states them, as one plant claim matched to that site and decided by Tosin (old → new):
  #   { action: "propose_site_fields", target: site id, slug or page address,
  #     fields: { "latitude" => "41.705993", "longitude" => "-110.5603", "eia_plant_id" => "68635" },
  #     quote:, source_url:, reason: }
  # Only a published top-level site (never a unit). Coordinates have 3 to 6 decimals (the directory keeps 6),
  # and the quote states each one: as a decimal, written as proposed (the source may give more digits), or in
  # degrees, minutes and seconds or degrees and decimal minutes, within the source's own precision. An EIA plant
  # ID is digits, in the quote, and no other site's.
  SITE_FIELDS = %w[latitude longitude eia_plant_id short_name].freeze
  COORDINATE = /\A-?\d{1,3}\.\d{3,6}\z/

  def self.propose_site_fields(row, directory, requeue)
    reason, quote = row["reason"].to_s.squish, row["quote"].to_s.squish
    fields = row["fields"].is_a?(Hash) ? row["fields"].transform_keys(&:to_s).transform_values { |value| value.to_s.strip } : {}
    fail_with = ->(why) { Row.new(id: nil, ok: false, error: why, created_ids: []) }
    return fail_with.call("give a reason") if reason.blank?
    return fail_with.call("keep the reason under #{MAX_REASON} characters") if reason.length > MAX_REASON
    return fail_with.call("give the quote that states it") if quote.blank?
    return fail_with.call("give fields: one or more of #{SITE_FIELDS.join(', ')}") if fields.empty?
    return fail_with.call("only #{SITE_FIELDS.join(', ')} can be proposed for a site") unless (fields.keys - SITE_FIELDS).empty?
    return fail_with.call("give a value for every field") if fields.values.any?(&:blank?)
    return fail_with.call("latitude and longitude go together: give both") if fields.key?("latitude") != fields.key?("longitude")
    { "latitude" => 90, "longitude" => 180 }.each do |name, limit|
      next unless fields.key?(name)

      value = fields[name]
      return fail_with.call("#{name} is a decimal with 3 to 6 decimal places (e.g. 41.705993)") unless value.match?(COORDINATE)
      return fail_with.call("#{name} must be between -#{limit} and #{limit}") unless BigDecimal(value).abs <= limit
      return fail_with.call("the quote must state the #{name} #{value}") unless DataQuality::Coordinates.stated?(quote, value, axis: name)
    end
    # A plant's short name (#935), as #927's for a company: the card's label, so 30 characters at most, in the quote as a whole word.
    if fields.key?("short_name")
      fields["short_name"] = fields["short_name"].squish # as Facility stores it
      return fail_with.call("a short name is #{MAX_SHORT_NAME} characters at most") if fields["short_name"].length > MAX_SHORT_NAME
      unless quote.match?(/(?<![[:alnum:]])#{Regexp.escape(fields['short_name'])}(?![[:alnum:]])/)
        return fail_with.call("the quote must contain the short name #{fields['short_name']}")
      end
    end
    if fields.key?("eia_plant_id")
      return fail_with.call("an EIA plant ID is digits (e.g. 68635)") unless fields["eia_plant_id"].match?(/\A\d{1,7}\z/)
      return fail_with.call("the quote must contain the EIA plant ID #{fields['eia_plant_id']}") unless quote.match?(/(?<!\d)(?<!\d\.)#{fields['eia_plant_id']}(?!\.?\d)/)
    end
    # A retry (same request_key) is answered first, whatever today's count.
    key = row["request_key"].presence&.to_s
    if key && (done = DqAction.find_by(request_key: key))
      return Row.new(id: done.candidate_id, ok: true, error: nil, created_ids: [ done.candidate_id ])
    end
    if DqAction.where(action: "propose_site_fields", created_at: Time.current.all_day).count >= DAILY_ROLES
      return fail_with.call("today's limit of #{DAILY_ROLES} is reached for propose_site_fields; ask Backend")
    end

    Candidate.transaction do
      found, error = target(row, directory, type: "Facility")
      raise Abort, error if error

      # Its own name, parent, docket and plant ID (a fact's record carries only its label and decision).
      site = directory.facility(id: found.id)
      raise Abort, "#{site.name} is a unit; propose its site's fields instead" if site.parent_id
      raise Abort, "#{site.name} isn't published yet" unless site.verification_status == "verified"
      # A docketed record is an NRC unit (Facility refuses it an EIA plant ID), even one with no site above it yet:
      # the ID would be refused at Tosin's Yes (25 Nov). Its coordinates are fine.
      if fields.key?("eia_plant_id") && site.nrc_docket.present?
        raise Abort, "#{site.name} is an NRC unit (docket #{site.nrc_docket}) with no site above it, and an EIA plant ID goes on a site; " \
          "propose its coordinates without the EIA plant ID"
      end
      if (plant = fields["eia_plant_id"]) && (holder = directory.facility(eia_plant_id: plant)) && holder.id != site.id
        raise Abort, "EIA plant ID #{plant} is already #{holder.name}'s (##{holder.id})"
      end

      source = DataQuality::Sources.find_or_create(url: row["source_url"].to_s)
      raise Abort, "the source: #{source.errors.to_sentence}" unless source.ok?

      # Its name (for the person deciding) and the proposed fields only: match finds the site by this action's
      # target, so its own docket or plant ID would only be more for the verifier to check (DQ, 25 Nov).
      payload = { "name" => site.name }.merge(fields)
      claim = Candidate.create!(source_id: source.ref.id, kind: "facility", status: "new", quote:, payload:, notes: "Data Quality proposed it: #{reason}")
      DqAction.create!(candidate: claim, action: "propose_site_fields", target_type: "Facility", target_id: site.id, reason:,
        before: {}, created: [], by: BY, request_key: key, after: stamp_of(claim))
      requeue << source.ref.source_kind
      Row.new(id: claim.id, ok: true, error: nil, created_ids: [ claim.id ])
    end
  rescue Abort => e
    Row.new(id: nil, ok: false, error: e.message, created_ids: [])
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    won = key && DqAction.find_by(request_key: key)
    raise e unless won

    Row.new(id: won.candidate_id, ok: true, error: nil, created_ids: [ won.candidate_id ])
  end

  # Undoing a proposed role: the claim closes, and a pending role it
  # proposed is taken off, while no person has decided either.
  def self.undo_role(action, claim, directory)
    # Never decided or reopened by a person since (reopenings only grow).
    untouched = %w[new matched needs_review].include?(claim.status) && claim.reviewed_by.nil? &&
      claim.reopenings.to_a == action.after.to_h.fetch("reopenings", [])
    raise Abort, "it was decided since, so it can't be undone here" unless untouched

    if claim.proposed_subject && claim.subject_id
      directory.lock_fact(type: claim.subject_type, id: claim.subject_id)
      raise Abort, "the role was decided since" unless directory.fact(type: claim.subject_type, id: claim.subject_id)&.verification_status == "pending"
      others = Candidate.where(subject_type: claim.subject_type, subject_id: claim.subject_id).where.not(id: claim.id).where(status: %w[new matched needs_review merged]).exists?
      raise Abort, "another source supports this role now, so it stays; close this claim instead" if others

      errors = directory.decide_fact(claim.kind, id: claim.subject_id, status: "rejected", by: BY, reason: "Data Quality undid #{action.action}").errors
      raise Abort, errors.to_sentence if errors.any?
    end
    claim.update!(status: "rejected", reviewed_by: BY, reviewed_at: Time.current, notes: "Undone by Data Quality")
    action.update!(undone_at: Time.current, undone_by: BY)
  end

  # The records an action created (not the quotes it added).
  def self.ids_of(created) = created.reject { |ref| ref["type"] == "Evidence" }.map { |ref| ref["id"] }

  class << self
    private
      # target: a company's (or plant's) id or slug (Infra: never a name).
      def target(row, directory, type: "Organization")
        value = row["target"].to_s.strip
        noun = type == "Facility" ? "plant" : "company"
        return [ nil, "give the #{noun}: its id or slug" ] if value.blank?

        # Its page's address works too (PM, 19 Nov): https://nuclear-directory.org/companies/oklo => oklo.
        value = value[%r{/#{type == "Facility" ? "plants" : "companies"}/([a-z0-9-]+)/?(?:[?#].*)?\z}, 1] || value if value.include?("/")
        ref = if value.match?(/\A\d+\z/) then directory.fact(type:, id: value.to_i)
        elsif type == "Organization" then directory.organization_by_slug(value)
        else directory.facility_by_slug(value)
        end
        record = ref && directory.fact(type:, id: ref.id)
        # A slug from before a rename or merge finds the company it now belongs to, also when the merged-away row
        # still holds it (Copilot); a closed id is never redirected.
        unless value.match?(/\A\d+\z/) || (record && %w[verified pending].include?(record.verification_status))
          id = directory.former_slug_id(type:, slug: value)
          record = directory.fact(type:, id:) if id
        end
        return [ nil, "no open #{noun} #{value.inspect}" ] unless record && %w[verified pending].include?(record.verification_status)

        [ record, nil ]
      end

      def same_as(candidate, row, record, reason, directory, created)
        candidate.update!(status: "needs_review", subject_type: "Organization", subject_id: record.id, proposed_subject: false,
          notes: "Data Quality: same as #{record.name}. #{reason}")
        return if row["add_alias"] || record.verification_status != "verified"

        # Only another way of naming it: its source is added, nothing changes.
        rest = candidate.payload.to_h.except("name", "aliases")
        return unless rest.empty? || DataQuality::Differences.changes(candidate, record, directory:)&.empty?

        # The source's own plug-in reads its quote (an NRC row isn't verbatim
        # in the stored HTML); without one, the stored text must contain it.
        in_source = DataQuality::Review.in_source(candidate) || ->(quote) { candidate.source.content_text.to_s.include?(quote.to_s) }
        had = directory.evidence_rows(type: "Organization", id: record.id).map(&:first)
        confirmation = directory.confirm(candidate, in_source:, add_evidence: true)
        # The quote it added, so Undo can take it back (Database).
        directory.evidence_rows(type: "Organization", id: record.id).reject { |row| had.include?(row.first) }.each do |evidence_id, source_id, quote|
          created << { "type" => "Evidence", "on" => "Organization", "record_id" => record.id, "id" => evidence_id, "source_id" => source_id, "quote" => quote }
        end
        if confirmation&.confirmed?
          candidate.update!(status: "confirmed", notes: "Data Quality: same as #{record.name}; adds the source. #{reason}")
        end
        nil
      end

      def propose(candidate, reason, directory, created)
        payload = candidate.payload.to_h
        plant = candidate.kind == "facility"
        type = plant ? "Facility" : "Organization"
        attributes = payload.slice(*(plant ? %w[name nrc_docket eia_plant_id facility_type status reactor_type capacity_mw thermal_power_kw city state] :
          # Filled before Tosin's Create (PM, 9 Nov): one Create publishes a complete company.
          %w[name hq_city hq_state description short_description website])).symbolize_keys
        result = directory.write_pending(candidate.kind, attributes, candidate:, crawl_run: candidate.crawl_run || CrawlRun.new(id: nil),
          verification: { status: "pending", by: BY, reason: })
        return "couldn't propose it: #{result.errors.to_sentence}" unless result.success?
        return "#{payload['name'].inspect} already exists (##{result.ref.id}); use same_as" unless result.created

        created << stamp(directory, { "type" => type, "id" => result.ref.id, "candidate_id" => candidate.id })
        # needs_review, so it's in Tosin's inbox without a verifier's call (Review.check_ids).
        candidate.update!(status: "needs_review", subject_type: type, subject_id: result.ref.id, proposed_subject: true,
          notes: "Data Quality: a new #{plant ? 'plant' : 'company'}. #{reason}")
        nil
      end

      def subsidiary_of(candidate, parent, reason, directory, created)
        error = propose(candidate, reason, directory, created)
        return error if error

        child = created.last
        name = candidate.payload.to_h["name"]
        link = Candidate.create!(source: candidate.source, crawl_run: candidate.crawl_run, kind: "relationship", quote: candidate.quote, status: "new",
          payload: { "from_organization" => { "name" => name }, "to_organization" => { "name" => parent.name }, "relationship_type" => "subsidiary_of" })
        result = directory.write_pending("relationship", { from_organization_id: child["id"], to_organization_id: parent.id, relationship_type: "subsidiary_of" },
          candidate: link, crawl_run: candidate.crawl_run || CrawlRun.new(id: nil), verification: { status: "pending", by: BY, reason: })
        return "couldn't propose the link: #{result.errors.to_sentence}" unless result.success?

        link.update!(status: "needs_review", subject_type: "Relationship", subject_id: result.ref.id, proposed_subject: true,
          notes: "Data Quality: #{name} is a subsidiary of #{parent.name}. #{reason}")
        created << stamp(directory, { "type" => "Relationship", "id" => result.ref.id, "candidate_id" => link.id, "link_claim" => true })
        nil
      end

      def end_type(candidate, end_key) = DataQuality::Stages::Match::LINK_ENDS.fetch(candidate.kind, {})[end_key]

      # The end named as that record now (a plant by its docket when it has
      # one), the claim's own wording kept as another name; then matched
      # again for its source. Nothing is written to the directory.
      def settle_end(candidate, end_key, record, reason, requeue)
        named = candidate.payload[end_key]
        return "its #{end_key} end is malformed" unless named.is_a?(Hash)

        settled = if end_type(candidate, end_key) == :facility
          # Its identifiers, so the rematch finds this record and not a namesake (a site by its EIA plant ID).
          values = record.values.to_h
          { "name" => record.name, "nrc_docket" => (record.nrc_docket || values["nrc_docket"]).presence,
            "eia_plant_id" => (record.eia_plant_id || values["eia_plant_id"]).presence }.compact
        else
          { "name" => record.name }
        end
        spelled = named["name"].to_s
        settled["aliases"] = [ *named["aliases"], (spelled unless spelled.blank? || spelled.casecmp?(record.name)) ].compact.uniq
        payload = candidate.payload.deep_dup.merge(end_key => settled)
        candidate.update!(status: "new", payload:, notes: "Data Quality: its #{end_key} is #{record.name}. #{reason}",
          ai_recommendation: nil, ai_reason: nil, ai_confidence: nil)
        requeue << candidate.source.source_kind
        nil
      end

      # How many decisions the record had when it was created, so Undo can
      # tell nobody has decided anything on it since.
      def stamp(directory, ref) = ref.merge("events" => directory.verification_history(type: ref["type"], id: ref["id"]).size)

      def close(candidate, reason, directory)
        candidate.update!(status: "rejected", reviewed_by: BY, reviewed_at: Time.current, notes: "Data Quality closed it: #{reason}")
        # A lead is never thrown away (#548).
        if candidate.kind == "organization" && DataQuality::Review.lead?(candidate) && (name = candidate.payload.to_h["name"]).present?
          directory.keep_lead(name:, key: "dq_close:#{candidate.id}", label: "Closed by Data Quality", url: candidate.source&.url)
        end
        nil
      end
  end
end
