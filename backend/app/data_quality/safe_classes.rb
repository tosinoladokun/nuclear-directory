# Safe classes (#306, option A): verifier recommendations that "Accept
# recommendations" takes without Data Quality's list, because Data
# Quality's rule says they can't change anything a person decided. The
# classes and their limits are in config/safe_verifier_classes.yml, which
# Data Quality owns; each is off until turned on there.
#
# A claim is safe only if every gate holds:
# - G1 the verifier recommends it now, confident enough
# - G2 it updates an existing published record, never creates one
# - G3 every field it changes is one the class allows, last written by the
#   pipeline from the same kind of source (Differences.pipeline_written?)
# - G4 nothing else is open on its record: no claim waiting for review, no
#   unresolved correction report
# - G5 it isn't from its source's first batch, the source's last fetch
#   returned 200, and the last match run checked for dropped facts
# - G6 its run doesn't propose too many safe changes (the cap)
# and the class's own: S1 is an update to a DOE "funds" link a person
# verified, whose award total doesn't drop by more than 20%.
#
#   DataQuality::SafeClasses.items(exclude: ids)  # => [Item, …]
#   DataQuality::SafeClasses.accept(items, by: "human:tosin") # => [Review::Result, …]
module DataQuality::SafeClasses
  CONFIG = YAML.safe_load_file(Rails.root.join("config/safe_verifier_classes.yml")).freeze
  # One claim a class covers. changes: { field => [old, new] }. why: why it
  # isn't safe, or nil. enabled: whether its class is on (off, the preview
  # shows what it would take). snapshot: the claim as the preview showed it.
  Item = Data.define(:candidate_id, :klass, :label, :enabled, :snapshot, :claim, :changes, :subject_type, :subject_id, :why) do
    def safe? = why.nil?
    def taken? = safe? && enabled
  end
  # The advisory lock namespace for a run's G6 count (with the run id).
  RUN_LOCK = 306_006
  # "$2.62 billion", "$921.7 million", "$750,000" in an award summary.
  TOTAL = /totaling \$([\d,]+(?:\.\d+)?)(?: (million|billion))?/
  SCALE = { nil => 1, "million" => 1_000_000, "billion" => 1_000_000_000 }.freeze

  class << self
    # Every claim a class covers that the verifier recommends, safe or not,
    # oldest first. exclude: claims Data Quality has its own call on.
    # only_enabled: skip classes that are off (a count of what Accept takes
    # needs nothing more). pending: the claims Data Quality's list will
    # approve in the same click: they take the run's allowance too, so the
    # cap is judged with them in. Run-level checks are read once per class;
    # the claims a class covers are at most one per DOE link a crawl changed.
    def items(exclude: [], only_enabled: false, pending: [], directory: DataQuality::DirectoryClient.new)
      CONFIG.fetch("classes").flat_map do |klass, config|
        next [] if only_enabled && config["enabled"] != true

        context = context_for(klass)
        claims = covered(klass).where.not(id: exclude).includes(:source).order(:id).to_a
        items = claims.map do |candidate|
          why, changes = evaluate(candidate, klass, context:, directory:)
          Item.new(candidate_id: candidate.id, klass:, label: config.fetch("label"), enabled: config["enabled"] == true,
            snapshot: snapshot(candidate), claim: DataQuality::Claim.describe(candidate), changes: changes || {},
            subject_type: candidate.subject_type, subject_id: candidate.subject_id, why:)
        end
        capped(items, config, claims, pending:, directory:)
      end
    end

    # The decision's reason in the record's history.
    def reason(item) = "Accepted the verifier's recommendation (safe class #{item.klass}: #{item.label})"

    def fingerprint_parts(items) = items.map { |item| [ item.candidate_id, item.klass, item.snapshot ] }

    # Approves these items (a plan's safe ones) as `by`'s decision, each
    # under its source's and its record's locks, with every gate but the cap
    # asked again there (the cap was the page's, which the click matched).
    def accept(items, by:, directory: DataQuality::DirectoryClient.new)
      DataQuality::Review.human!(by)
      items.sort_by(&:candidate_id).map do |item|
        result = nil
        Candidate.transaction do
          source_id = Candidate.where(id: item.candidate_id).pick(:source_id)
          result = skipped(item, "this fact no longer exists") and next unless source_id

          ::Source.lock.find(source_id)
          candidate = Candidate.lock.find_by(id: item.candidate_id)
          result = skipped(item, "this fact no longer exists") and next unless candidate
          result = skipped(item, "it changed after the page loaded") and next unless snapshot(candidate) == item.snapshot
          # G6 again, under its run's lock: another approval from the run may
          # have used the allowance since the page loaded.
          if (over = over_cap(candidate, item.klass, directory:))
            result = skipped(item, "it's no longer safe: #{over}")
            next
          end

          check = ->(locked) { why_not(locked, item.klass, directory:) }
          result = DataQuality::Review.approve([ candidate.id ], by:, reason: reason(item), only_recommended: true, safe_check: check,
            directory:).first
          raise ActiveRecord::Rollback unless result.ok?
        end
        result
      rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
        skipped(item, "someone was deciding on it just then; try again")
      end
    end

    # Takes a run's G6 lock (held to the end of the transaction). Safe
    # acceptance takes it before counting; any approval path that should
    # count against a run's allowance can take it too.
    def lock_run(run_id) = Candidate.connection.execute("SELECT pg_advisory_xact_lock(#{RUN_LOCK}, (#{Integer(run_id)} % 2147483647)::int)")

    # Why a claim isn't safe in its class, or nil: every gate but the cap,
    # each read fresh (Accept asks this under the record's lock).
    def why_not(candidate, klass, directory:)
      return "Data Quality doesn't recommend it now" unless covered(klass).exists?(candidate.id)

      evaluate(candidate, klass, context: context_for(klass), directory:).first
    end

    private
      # [why it isn't safe or nil, what it changes or nil]. G1's "recommended
      # now" is the caller's: items reads only covered claims.
      def evaluate(candidate, klass, context:, directory:)
        config = CONFIG.fetch("classes").fetch(klass)
        why = catch(:unsafe) do
          # G5's run checks first: they're the same for every claim.
          throw :unsafe, context[:run_problem] if context[:run_problem]
          # G1
          if candidate.ai_confidence.to_f < config.fetch("min_confidence")
            throw :unsafe, "Data Quality's confidence is below #{config.fetch('min_confidence')}"
          end

          changes = gates(candidate, config, context, directory)
          return [ nil, changes ]
        end
        [ why, nil ]
      end

      # Every gate after G1 and the run checks; the changes when all hold,
      # else throws :unsafe with why.
      def gates(candidate, config, context, directory)
        # G2, with S1's own: a published DOE funds link, both ends published, a person verified it.
        throw :unsafe, "it isn't attached to a link yet" unless candidate.subject_type == "Relationship" && candidate.subject_id

        type, id = candidate.subject_type, candidate.subject_id
        record = directory.fact(type:, id:)
        throw :unsafe, "its link isn't verified and public" unless record&.verification_status == "verified" && directory.published?(type:, id:)

        values = record.values
        unless values["relationship_type"] == config.fetch("relationship_type") && values["from_organization_name"] == config.fetch("funder")
          throw :unsafe, "it isn't a #{config.fetch('funder')} #{config.fetch('relationship_type')} link"
        end
        unless [ values["from_organization_id"], values["to_organization_id"] ].all? { |end_id| directory.published?(type: "Organization", id: end_id) }
          throw :unsafe, "a company on its link isn't public"
        end
        unless directory.verification_history(type:, id:).any? { |event| event.to_status == "verified" && event.by.to_s.start_with?("human:") }
          throw :unsafe, "no person has verified its link"
        end

        # G3
        changes = DataQuality::Differences.changes(candidate, record, directory:) or throw :unsafe, "it changes a field that can't be compared"
        throw :unsafe, "it changes nothing" if changes.empty?

        others = changes.keys - config.fetch("fields")
        if others.any?
          allowed = config.fetch("fields").map { |name| label(name) }.to_sentence(two_words_connector: " or ", last_word_connector: ", or ")
          throw :unsafe, "it changes #{others.map { |name| label(name) }.to_sentence}, not only #{allowed}"
        end
        throw :unsafe, "it changes a value a person wrote" unless DataQuality::Differences.pipeline_written?(candidate, record, directory:)

        # G4
        waiting = Candidate.where(subject_type: type, subject_id: id).where.not(id: candidate.id)
        throw :unsafe, "another fact on its link waits for review" if waiting.where(status: "needs_review").exists?
        throw :unsafe, "a correction report on its page isn't resolved" if directory.open_corrections?(type:, id:)

        # G5, this claim's part (the run's is in context_for)
        throw :unsafe, DataQuality::Review::FIRST_BATCH if candidate.crawl_run_id && context[:firsts][candidate.source.source_kind] == candidate.crawl_run_id
        throw :unsafe, "its source's last fetch didn't return 200" unless candidate.source.http_status == 200
        # Read in the latest crawl that fetched: an answer that leaves a
        # recipient out leaves its page as it was, still 200 and ok.
        unless context[:crawled_at] && candidate.source.fetched_at && candidate.source.fetched_at >= context[:crawled_at]
          throw :unsafe, "its source wasn't in the last crawl's answer"
        end
        # The dropped-fact check is per source: a run skips it for a page
        # that still has a claim to place, or that would drop too much.
        unless context[:checked_sources].include?(candidate.source_id)
          throw :unsafe, "the last match run didn't check its source for dropped facts"
        end

        # S1: the award total doesn't drop too far.
        if changes.key?("description")
          before, after = changes.fetch("description").map { |text| total(text) }
          throw :unsafe, "its award total can't be read" unless before && after
          # The summaries round ("$1.3 million"), so the drop is judged at its
          # largest: the old total rounded down to its most, the new to its least.
          if after.first - after.last < (before.first + before.last) * (1 - config.fetch("max_total_drop"))
            throw :unsafe, "its award total may drop by more than #{(config.fetch('max_total_drop') * 100).round}%"
          end
        end

        changes
      end

      # What's the same for every claim of a class, read once: the first
      # batches, G5's run checks and the sources the last match checked for
      # dropped facts. A run problem: the latest crawl or match attempt
      # (whatever its status) didn't succeed, or the source's API index
      # answered with anything but 200 on its last fetch (a failed fetch
      # leaves each recipient's page as it was).
      def context_for(klass)
        config = CONFIG.fetch("classes").fetch(klass)
        kind = config.fetch("source_kind")
        latest = ->(stage) { CrawlRun.where(stage:, source_kind: kind).order(started_at: :desc, id: :desc).first }
        crawl, match, verify = latest.("crawl"), latest.("match"), latest.("verify")
        index = ::Source.where(source_kind: config["index_source_kind"]).order(fetched_at: :desc, id: :desc).first if config["index_source_kind"]
        problem =
          if crawl.nil? || crawl.status != "succeeded" then "the source's last crawl didn't finish"
          # An answer that couldn't be read (malformed JSON) is a 200 with a status reason.
          elsif config["index_source_kind"] && (index&.http_status != 200 || index.status_reason.present?)
            "the source's last fetch didn't return 200"
          elsif match.nil? || match.status != "succeeded" then "the last match run didn't finish"
          # Verify saves its recommendations one claim at a time, and a run
          # that fails or is cut off keeps what it saved: the run's set (and
          # so the cap) is only whole once its latest run has succeeded.
          elsif verify&.status == "running" then "Data Quality is still checking this source"
          elsif verify.nil? || verify.status != "succeeded" then "Data Quality's last check didn't finish"
          end
        # The last crawl that fetched: a same-day rerun answers "skipped_recent"
        # and stamps nothing, so it doesn't count as the answer pages are judged by.
        fetched = CrawlRun.where(stage: "crawl", source_kind: kind, status: "succeeded").order(started_at: :desc, id: :desc)
          .find { |run| [ nil, "ok" ].include?(run.stats["api"]) }
        { firsts: DataQuality::Review.first_batches, run_problem: problem, crawled_at: fetched&.started_at,
          checked_sources: Array(match&.stats&.dig("dropped_checked_source_ids")).to_set }
      end

      # The recommended claims a class covers: its source and kind, with no
      # call from Data Quality (its list decides those).
      def covered(klass)
        config = CONFIG.fetch("classes").fetch(klass)
        Candidate.recommended.where(kind: config.fetch("kind"), dq_recommendation: nil)
          .where(sources: { source_kind: config.fetch("source_kind") })
      end

      # G6: a run that proposes more safe changes than the cap, or more than
      # its share of the source's published facts, gets none of them taken.
      # What the run already had approved counts too, so accepting some and
      # then the rest can't pass the cap in two clicks. So do the approvals
      # Accept will make in the same click: they take the run's allowance too.
      def capped(items, config, claims, pending:, directory:)
        cap = CONFIG.fetch("cap")
        runs = claims.to_h { |candidate| [ candidate.id, candidate.crawl_run_id ] }
        limit, facts = limit_for(config, directory:)
        approved = Candidate.joins(:source).where(sources: { source_kind: config.fetch("source_kind") }, kind: config.fetch("kind"),
          status: "merged", crawl_run_id: runs.values.uniq).group(:crawl_run_id).count
        proposed = items.select(&:safe?).group_by { |item| runs[item.candidate_id] }.transform_values(&:size)
        approving = pending_counts(config, pending, runs)
        items.map do |item|
          run = runs[item.candidate_id]
          total = proposed.fetch(run, 0) + approved.fetch(run, 0) + approving.fetch(run, 0)
          next item unless item.safe? && total > limit

          notes = []
          notes << "#{approved[run]} already approved" if approved[run].to_i.positive?
          notes << "#{approving[run]} approved in this click" if approving[run].to_i.positive?
          item.with(why: "its run proposes #{total} changes#{notes.empty? ? "" : " (#{notes.join(", ")})"}, over the limit of #{limit} " \
            "(#{cap.fetch('max_items')}, or #{(cap.fetch('max_share') * 100).round}% of the source's #{facts} public facts)")
        end
      end

      # The Data Quality approvals Accept will make in the same click, per
      # run. Only the class's own kind and source count, like the merged ones.
      def pending_counts(config, ids, runs)
        return {} if ids.empty?

        Candidate.joins(:source).where(id: ids, sources: { source_kind: config.fetch("source_kind") },
          kind: config.fetch("kind"), crawl_run_id: runs.values.uniq).group(:crawl_run_id).count
      end

      # The run's limit and its source's public facts: [limit, facts].
      def limit_for(config, directory:)
        cap = CONFIG.fetch("cap")
        facts = directory.published_count_backed_by(source_ids: ::Source.where(source_kind: config.fetch("source_kind")).ids)
        [ [ cap.fetch("max_items"), (facts * cap.fetch("max_share")).floor ].min, facts ]
      end

      # At Accept, under the run's lock: why taking one more change from this
      # claim's run would pass its limit (what the run already has approved,
      # this click's earlier items included), or nil.
      def over_cap(candidate, klass, directory:)
        return unless candidate.crawl_run_id

        config = CONFIG.fetch("classes").fetch(klass)
        lock_run(candidate.crawl_run_id)
        limit, = limit_for(config, directory:)
        approved = Candidate.joins(:source).where(sources: { source_kind: config.fetch("source_kind") }, kind: config.fetch("kind"),
          status: "merged", crawl_run_id: candidate.crawl_run_id).count
        "its run already has #{approved} approved changes, the limit is #{limit}" if approved + 1 > limit
      end

      def label(name) = DataQuality::Claim::LABELS.fetch(name) { name.humanize(capitalize: false) }

      # [dollars, how far rounding may have moved it], or nil. "$1.3 million"
      # is anything from $1.25 to $1.35 million: 0.05 million either way.
      def total(text)
        match = TOTAL.match(text.to_s) or return
        decimals = match[1][/\.(\d+)\z/, 1].to_s.size
        scale = SCALE.fetch(match[2])
        [ BigDecimal(match[1].delete(",")) * scale, BigDecimal("0.5") * scale / (10**decimals) ]
      end

      # The claim as the preview showed it, and as the verifier judged it.
      def snapshot(candidate)
        Digest::SHA256.hexdigest([ candidate.payload, candidate.quote, candidate.subject_type, candidate.subject_id, candidate.reopenings,
          candidate.ai_source_sha256, candidate.ai_confidence&.to_s, candidate.verify_run_id ].to_json)
      end

      def skipped(item, why) = DataQuality::Review::Result.new(candidate_id: item.candidate_id, ref: nil, errors: [ why ])
  end
end
