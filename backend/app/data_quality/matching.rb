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
  # Stops an action part-way: everything it wrote rolls back, and the message is the row's error.
  class Abort < StandardError; end

  Row = Data.define(:id, :ok, :error, :created_ids) do
    def to_h = { id:, ok:, error:, created_ids: }
  end

  def self.apply(rows, directory: DataQuality::DirectoryClient.new)
    # Each source matched again once per request, however many of its ends
    # were settled (Infra: verify is the AI step).
    requeue = Set.new
    Array(rows).map { |row| apply_one(row.to_h.stringify_keys, directory, requeue) }
      .tap { requeue.each { |kind| DataQuality::RunJob.perform_later(kind, only: %w[match verify]) } }
  end

  def self.apply_one(row, directory, requeue = Set.new)
    id, action, reason = row["id"].to_i, row["action"].to_s, row["reason"].to_s.squish
    fail_with = ->(why) { Row.new(id:, ok: false, error: why, created_ids: []) }
    return fail_with.call("action must be one of #{DqAction::ACTIONS.join(', ')}") unless DqAction::ACTIONS.include?(action)
    return fail_with.call("give a reason") if reason.blank?
    return fail_with.call("keep the reason under #{MAX_REASON} characters") if reason.length > MAX_REASON
    if %w[new subsidiary_of].include?(action) && DqAction.where(action: %w[new subsidiary_of], created_at: Time.current.all_day).count >= DAILY_CREATES
      return fail_with.call("today's limit of #{DAILY_CREATES} new companies is reached; ask Backend")
    end
    if action == "close" && DqAction.where(action: "close", created_at: Time.current.all_day).count >= DAILY_CLOSES
      return fail_with.call("today's limit of #{DAILY_CLOSES} closes is reached; ask Backend")
    end

    key = row["request_key"].presence&.to_s
    Candidate.transaction do
      candidate = Candidate.lock.find_by(id:) or next fail_with.call("no claim ##{id}")
      # Sent again (the same key, or the same action already done): fine, nothing more happens.
      # A live action counts only while the claim is still as it left it
      # (a person may have reopened it since).
      done = (DqAction.find_by(request_key: key) if key) ||
        DqAction.live.where(candidate_id: id, action:).order(:id).last&.then { |last| last if left_as?(last, candidate) }
      next Row.new(id:, ok: true, error: nil, created_ids: ids_of(done.created)) if done
      # Close applies to any open claim (a link, a deal term, news); the
      # others settle a company, so they need a company claim.
      # same_as with an end settles that end of a link claim (#548): which
      # company or plant it names. Otherwise only close applies to a link.
      end_key = row["end"].presence&.to_s
      if end_key
        next fail_with.call("an end goes with same_as") unless action == "same_as"
        next fail_with.call("#{end_key.inspect} isn't an end of a #{candidate.kind} claim") unless end_type(candidate, end_key)
      elsif candidate.kind != "organization" && action != "close"
        next fail_with.call("it isn't a company claim; only close applies to it (or same_as with an end)")
      end
      # No longer open (settled meanwhile): skipped, not an error (Infra).
      next Row.new(id:, ok: true, error: "skipped: it's already attached or decided (#{candidate.status})", created_ids: []) unless
        OPEN.include?(candidate.status) && candidate.subject_id.nil?

      before = candidate.slice(:status, :subject_type, :subject_id, :proposed_subject, :notes, :reviewed_by, :reviewed_at, :payload).as_json
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
      raise Abort, "the claim was changed since (decided, reopened or moved by a merge), so it can't be undone here" unless left_as?(action, candidate)

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
        others = Candidate.where(subject_type: type, subject_id: id).where.not(id: ref["candidate_id"]).where.not(status: "rejected").exists?
        raise Abort, "#{type} ##{id} was decided or claimed since, so it can't be undone here" if decided || others

        Candidate.find_by(id: ref["candidate_id"])&.update!(status: "rejected", reviewed_by: BY, reviewed_at: Time.current, notes: "Undone by Data Quality") if ref["link_claim"]
        errors = directory.decide_fact(ref["type"].underscore, id: ref["id"], status: "rejected", by: BY, reason: "Data Quality undid #{action.action}").errors
        raise Abort, errors.to_sentence if errors.any?
      end
      candidate.update!(action.before.slice("status", "subject_type", "subject_id", "proposed_subject", "notes", "reviewed_by", "reviewed_at", "payload"))
      action.update!(undone_at: Time.current, undone_by: BY)
      nil
    end
  rescue Abort => e
    e.message
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    "someone was deciding on it just then; try again"
  end

  STAMPED = %w[status subject_type subject_id proposed_subject reviewed_by payload].freeze

  # The claim as an action left it, compared under its lock: anything since
  # (a decision, a reopen, a merge repointing it) means it isn't the same.
  def self.stamp_of(candidate) = candidate.slice(*STAMPED).as_json
  # Only the fields the action stamped (actions before payload was stamped keep working).
  def self.left_as?(action, candidate) = action.after.present? && stamp_of(candidate).slice(*action.after.keys) == action.after

  # The records an action created (not the quotes it added).
  def self.ids_of(created) = created.reject { |ref| ref["type"] == "Evidence" }.map { |ref| ref["id"] }

  class << self
    private
      # target: a company's (or plant's) id or slug (Infra: never a name).
      def target(row, directory, type: "Organization")
        value = row["target"].to_s
        noun = type == "Facility" ? "plant" : "company"
        return [ nil, "give the #{noun}: its id or slug" ] if value.blank?

        ref = if value.match?(/\A\d+\z/) then directory.fact(type:, id: value.to_i)
        elsif type == "Organization" then directory.organization_by_slug(value)
        else directory.facility_by_slug(value)
        end
        record = ref && directory.fact(type:, id: ref.id)
        return [ nil, "no open #{noun} #{value.inspect}" ] unless record && %w[verified pending].include?(record.verification_status)

        [ record, nil ]
      end

      def same_as(candidate, row, record, reason, directory, created)
        candidate.update!(status: "matched", subject_type: "Organization", subject_id: record.id, proposed_subject: false,
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
        attributes = payload.slice(*%w[name hq_city hq_state description website]).symbolize_keys
        result = directory.write_pending("organization", attributes, candidate:, crawl_run: candidate.crawl_run || CrawlRun.new(id: nil),
          verification: { status: "pending", by: BY, reason: })
        return "couldn't propose it: #{result.errors.to_sentence}" unless result.success?
        return "#{payload['name'].inspect} already exists (##{result.ref.id}); use same_as" unless result.created

        created << stamp(directory, { "type" => "Organization", "id" => result.ref.id, "candidate_id" => candidate.id })
        candidate.update!(status: "matched", subject_type: "Organization", subject_id: result.ref.id, proposed_subject: true,
          notes: "Data Quality: a new company. #{reason}")
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

        link.update!(status: "matched", subject_type: "Relationship", subject_id: result.ref.id, proposed_subject: true,
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
          { "name" => record.name, "nrc_docket" => (record.nrc_docket || record.values.to_h["nrc_docket"]).presence }.compact
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
