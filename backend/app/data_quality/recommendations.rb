# Data Quality's recommendations (#306): its call on each claim it
# reviewed, approve or reject with a reason, and one button that accepts
# them all as a person's decision.
#
# Data Quality sends the list in a message; Tosin pastes it into Checks:
#
#   # DOE awards, 18 Oct
#   1234 approve: the award page names General Atomics as the recipient
#   1235 reject: a subcontract, not an award to this company
#
# Blank lines and lines starting with # are skipped; any other line that
# isn't "<claim id> approve|reject: <reason>" is an error, never guessed at.
# A JSON array of { "id", "recommendation", "reason" } works too. Recording
# a list decides nothing: Accept does, and only for claims that are still
# as Data Quality saw them and pass the same checks as Approve all, except
# the first-batch hold, which is what Data Quality's review is for.
#
#   DataQuality::Recommendations.record(text, by: "human:tosin")  # => Recorded
#   DataQuality::Recommendations.plan                             # => Plan (accept: […], left: […])
#   DataQuality::Recommendations.accept(plan.accept, by: "human:tosin") # => [Review::Result, …]
#
# The plan also lists the verifier's own recommendations in safe classes
# (DataQuality::SafeClasses): Accept takes those of a class that's on, in
# the same click, and one fingerprint covers both lists.
module DataQuality::Recommendations
  CALLS = %w[approve reject].freeze
  REASON_LIMIT = 500
  # What every accepted decision's history says, before Data Quality's reason.
  ACCEPTED = "Accepted Data Quality's recommendation".freeze
  OPEN = %w[new matched needs_review].freeze
  # The largest id a claim can have (a bigint); a longer number is no claim.
  MAX_ID = (2**63) - 1
  LINE = /\A(\d+)\s+(approve|reject)\s*:\s*(.+?)\z/i

  # errors: [LineError, …], each line that wasn't added: where it was, its
  # text as pasted, and what's wrong with it.
  Recorded = Data.define(:recorded, :errors)
  LineError = Data.define(:line, :text, :problem)
  # One recommendation as the preview shows it. snapshot: the claim's digest
  # when Data Quality made its call (part of the fingerprint, and checked
  # again under the decision's locks). why: why it's left for a person (nil
  # when it will be accepted). waiting: it's in the queue a fact page
  # decides from (recommended or needs review); otherwise it's decided on
  # the claim's own page.
  Item = Data.define(:candidate_id, :call, :reason, :snapshot, :claim, :subject_type, :subject_id, :why, :waiting)
  # safe: SafeClasses items, safe or not.
  Plan = Data.define(:accept, :left, :safe) do
    # The exact list Accept will act on, both groups, compared on the click (as Approve all's).
    def fingerprint = DataQuality::Recommendations.fingerprint(accept, safe_accept)
    # The verifier's safe recommendations Accept takes (their class is on).
    def safe_accept = safe.select(&:taken?)
    # Safe, but their class is off: shown as what Accept would take.
    def safe_dry = safe.select { |item| item.safe? && !item.enabled }
    def safe_left = safe.reject(&:safe?)
    def nothing? = accept.empty? && safe_accept.empty?
  end

  class << self
    # Parses the pasted list and records each call on its claim. Returns
    # Recorded(recorded: count, errors: [LineError, …]).
    def record(text, by:)
      DataQuality::Review.human!(by)
      calls, errors = parse(text.to_s)
      recorded = 0
      calls.each do |line, id, call, reason, text|
        candidate = Candidate.find_by(id:) if id <= MAX_ID
        next errors << LineError.new(line:, text:, problem: "there's no fact #{id}") unless candidate
        next errors << LineError.new(line:, text:, problem: "fact #{id} is already #{candidate.status}") unless OPEN.include?(candidate.status)

        candidate.update!(dq_recommendation: call, dq_reason: reason, dq_by: by, dq_at: Time.current, dq_payload_sha256: digest(candidate))
        recorded += 1
      end
      Recorded.new(recorded:, errors:)
    end

    # Every open claim with a recommendation: those Accept will act on, and
    # those left for a person, each with why.
    # The checks it needs are read for the whole list at once (a few
    # queries, however many recommendations), as Approve all's are.
    # only_enabled_safe: leave out safe classes that are off (Checks only
    # counts what Accept takes).
    def plan(only_enabled_safe: false, directory: DataQuality::DirectoryClient.new)
      claims = Candidate.where(status: OPEN).where.not(dq_recommendation: nil).includes(:source).order(:id).to_a
      context = context_for(claims, directory:)
      items = claims.map do |candidate|
        Item.new(candidate_id: candidate.id, call: candidate.dq_recommendation, reason: candidate.dq_reason, snapshot: candidate.dq_payload_sha256,
          claim: DataQuality::Claim.describe(candidate), subject_type: candidate.subject_type, subject_id: candidate.subject_id,
          why: why_left(candidate, directory:, **context), waiting: candidate.status_needs_review? || context[:recommended].include?(candidate.id))
      end
      items = one_approval_per_record(items)
      accept, left = items.partition { |item| item.why.nil? }
      # The approvals Accept will make in this click take the safe classes'
      # run allowance too, so they count before the preview is built.
      pending = accept.select { |item| item.call == "approve" }.map(&:candidate_id)
      safe = DataQuality::SafeClasses.items(exclude: claims.map(&:id), only_enabled: only_enabled_safe, pending:, directory:)
      Plan.new(accept:, left:, safe: one_safe_approval_per_record(safe, accept))
    end

    # What the person saw: each claim, its call and reason, and the claim as Data Quality saw it.
    # Whether this claim's recommendation still stands: it has one, and the
    # claim is as Data Quality saw it (not changed or reopened since).
    def current?(candidate) = candidate.dq_recommendation.present? && candidate.dq_payload_sha256 == digest(candidate)

    def fingerprint(items, safe = [])
      Digest::SHA256.hexdigest([ items.map { |item| [ item.candidate_id, item.call, item.reason, item.snapshot ] },
        DataQuality::SafeClasses.fingerprint_parts(safe) ].to_json)
    end

    # Accepts these recommendations (a plan's items) as `by`'s decision. Each
    # is locked as a decision locks it (its source, then the claim), checked
    # again under those locks against what the person saw (the same call,
    # reason and claim) and decided while they're held. One that no longer
    # qualifies is skipped with why. Returns a Review::Result per claim.
    def accept(items, by:, directory: DataQuality::DirectoryClient.new)
      DataQuality::Review.human!(by)
      items.sort_by(&:candidate_id).map do |item|
        result = nil
        Candidate.transaction do
          source_id = Candidate.where(id: item.candidate_id).pick(:source_id)
          result = skipped(item, "this fact no longer exists") and next unless source_id

          ::Source.lock.find(source_id)
          # Read again under the source's lock: a crawl's extract can replace the claim meanwhile.
          candidate = Candidate.lock.find_by(id: item.candidate_id)
          result = skipped(item, "this fact no longer exists") and next unless candidate
          unless [ candidate.dq_recommendation, candidate.dq_reason, candidate.dq_payload_sha256 ] == [ item.call, item.reason, item.snapshot ]
            result = skipped(item, "Data Quality's call on it changed after the page loaded")
            next
          end
          why = why_left(candidate, directory:, **context_for([ candidate ], directory:))
          result = skipped(item, why) and next if why

          reason = "#{ACCEPTED}: #{candidate.dq_reason}"
          result =
            if candidate.dq_recommendation == "approve"
              DataQuality::Review.approve([ candidate.id ], by:, reason:, only_recommended: true, data_quality_reviewed: true,
                source_held: source_hold?(candidate), directory:).first
            else
              DataQuality::Review.reject([ candidate.id ], by:, reason:, directory:).first
            end
          # The decision's own rollback only reaches this transaction's end:
          # undo all of it, so a failed one stays open to try again.
          raise ActiveRecord::Rollback unless result.ok?
        end
        result
      rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
        skipped(item, "someone was deciding on it just then; try again")
      end
    end

    private
      # [[line number, id, call, reason, text], …] and [LineError, …].
      def parse(text)
        return parse_json(text) if text.lstrip.start_with?("[")

        calls, errors = [], []
        text.each_line.with_index(1) do |raw, line|
          stripped = raw.strip
          # A comment, or a recommendation commented out ("#1234 …"): skipped.
          next if stripped.empty? || stripped.start_with?("#")

          match = LINE.match(stripped)
          unless match
            next errors << LineError.new(line:, text: stripped.truncate(120), problem: "it isn't “<id> approve: <reason>” or “… reject: …”")
          end

          calls << [ line, match[1].to_i, match[2].downcase, match[3].truncate(REASON_LIMIT), stripped.truncate(120) ]
        end
        [ calls, errors ]
      end

      def parse_json(text)
        rows = JSON.parse(text)
        raise JSON::ParserError, "not a list" unless rows.is_a?(Array)

        calls, errors = [], []
        rows.each.with_index(1) do |row, line|
          id, call, reason = row.is_a?(Hash) ? row.values_at("id", "recommendation", "reason") : []
          text = row.to_json.truncate(120)
          unless id.to_s.match?(/\A\d+\z/) && CALLS.include?(call.to_s.downcase) && reason.present?
            next errors << LineError.new(line:, text:, problem: "it needs an id, a recommendation (approve or reject) and a reason")
          end

          calls << [ line, id.to_i, call.to_s.downcase, reason.to_s.strip.truncate(REASON_LIMIT), text ]
        end
        [ calls, errors ]
      rescue JSON::ParserError => error
        [ [], [ LineError.new(line: 1, text: text.strip.truncate(120), problem: "the list isn't valid JSON: #{error.message.truncate(80)}") ] ]
      end

      def skipped(item, why) = DataQuality::Review::Result.new(candidate_id: item.candidate_id, ref: nil, errors: [ why ])

      # Approving one claim is a person's decision on its record, which then
      # holds every other claim on it. So Accept takes one approval per
      # record (the first) and leaves the rest for a person, as the preview
      # says.
      def one_approval_per_record(items)
        seen = Set.new
        items.map do |item|
          next item unless item.why.nil? && item.call == "approve" && item.subject_id
          next item if seen.add?([ item.subject_type, item.subject_id ])

          item.with(why: "another recommendation in this list approves the same record; decide this one after it")
        end
      end

      # The same for safe items: none approves a record that Data Quality's
      # list, or an earlier safe item, already approves.
      def one_safe_approval_per_record(safe, accept)
        seen = accept.select { |item| item.call == "approve" && item.subject_id }.to_set { |item| [ item.subject_type, item.subject_id ] }
        safe.map do |item|
          next item unless item.safe? && item.subject_id
          next item if seen.add?([ item.subject_type, item.subject_id ])

          item.with(why: "another item in this list approves the same link; it's decided first")
        end
      end

      # The checks' data for these claims, each read once: the first batches,
      # which claims the verifier recommends now, and which attached records
      # a person decided.
      def context_for(claims, directory:)
        recommended = Candidate.recommended.where(id: claims.map(&:id)).pluck(:id).to_set
        decided = claims.select(&:subject_id).group_by(&:subject_type).flat_map do |type, group|
          directory.human_decided_ids(type:, ids: group.map(&:subject_id)).map { |id| [ type, id ] }
        end.to_set
        { firsts: DataQuality::Review.first_batches, recommended:, decided: }
      end

      # nil when Accept may act on it; otherwise why a person decides it.
      def why_left(candidate, directory:, firsts:, recommended:, decided:)
        return "it's already #{candidate.status}" unless OPEN.include?(candidate.status)
        return "it changed after Data Quality looked at it" unless candidate.dq_payload_sha256 == digest(candidate)
        # Filling in another record's details (an "identify" claim) is a change
        # to a record a person decides on its own page, with its own history.
        return "it fills in a record's details; decide it on its own page" if directory.enrichment?(candidate)
        return if candidate.dq_recommendation == "reject"

        # A claim its source holds for a person's review (a new source's first
        # read, a replacement): Data Quality's approve is that review, as it is
        # for the first batch, so the checker's verdict isn't needed. Every
        # other check stands, and a person's decision is never overwritten.
        if source_hold?(candidate)
          # No checker verdict to say the source still holds it: its quote must.
          plugin = DataQuality::Plugin.for(candidate.source.source_kind)
          return "its quote isn't in the source any more" unless plugin.quote_in_source?(candidate.source, candidate.quote)
        else
          return "the app's checker didn't recommend it" unless candidate.ai_recommendation == "recommend_publish"
          return "it's waiting for a person's review" if candidate.status_needs_review?
          return "its source changed after the app's checker checked it" unless recommended.include?(candidate.id)
        end
        return "its company or plant isn't settled yet" unless candidate.subject_id

        held = DataQuality::Review.held_reason(candidate, directory:, firsts:, decided: decided.include?([ candidate.subject_type, candidate.subject_id ]))
        held unless DataQuality::Review::REVIEWED_HOLDS.include?(held)
      end

      # Held in review only by its source's own hold (Plugin#hold_for_review),
      # with that hold's reason still the note, so nothing else held it.
      def source_hold?(candidate)
        return false unless candidate.status_needs_review?

        reason = DataQuality::Plugin.for(candidate.source.source_kind).hold_for_review(candidate)
        return false if reason.blank?

        # The hold's note exactly, or with only the settle sentence Verify keeps
        # (#391): any other warning added after it means something else holds it.
        rest = candidate.notes.to_s.delete_prefix(reason)
        candidate.notes.to_s.start_with?(reason) && (rest.empty? || rest.match?(/\A\. #{DataQuality::Stages::Match::SETTLED.source}\z/))
      rescue DataQuality::Plugin::UnknownSourceKind
        false
      end
      # Also asked by Review.inbox_kind (#548).
      public :source_hold?

      # The claim as Data Quality saw it: what it says and what it's attached to.
      # Reopening counts as a change: a reopened claim needs a fresh call.
      def digest(candidate) = Digest::SHA256.hexdigest([ candidate.payload, candidate.quote, candidate.subject_type, candidate.subject_id, candidate.reopenings ].to_json)
  end
end
