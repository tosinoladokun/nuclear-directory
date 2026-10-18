# How a human decides on what the pipeline found (#85). The verifier only
# recommends; nothing is published except from here, by a person, from the
# admin (#86). The admin calls only this module: it never touches candidates,
# FactWriter or directory models itself.
#
# Candidates (claims the pipeline extracted from a source):
#   Review.candidates(queue: :recommended, run_id:, reason:)  # what to decide on
#   Review.approve(ids, by: "human:tosin")                     # publish, bulk
#   Review.edit_and_approve(id, attributes: { "state" => "NJ" }, by:)
#   Review.reject(ids, by:, reason:)
# Directory facts (published, or waiting without a candidate, e.g. seed facts
# loaded as pending):
#   Review.pending_facts(kind:)
#   Review.approve_fact(type:, id:, by:, attributes: {})       # also republish
#   Review.reject_fact(type:, id:, by:, reason:)
#   Review.unpublish(type:, id:, by:, reason:)
#   Review.history(type:, id:)
#   Review.fact(type:, id:)                                   # one fact, any kind
#
# Every action is a human's (by: "human:…") and returns Results; a refused
# write (e.g. an edit that duplicates another fact) comes back as errors,
# never raises.
module DataQuality::Review
  # A merge (#142): errors, or what moved ("3 aliases, 2 evidence").
  MergeResult = Data.define(:errors, :moved) do
    def ok? = errors.empty?
  end
  Result = Data.define(:candidate_id, :ref, :errors) do
    def ok? = errors.empty?
  end

  # A candidate as the admin shows it. record: the directory fact it's
  # attached to (DirectoryClient::Record: name, decision, values), or nil.
  # differences: { "state" => ["NJ", "DE"] } ([human-verified, this source])
  # when it disagrees with a human-verified record; approving would apply the
  # source's value. found_by: the model of the run that extracted it (nil for
  # hand-made ones).
  # category: which of the Checks screen's groups it's in (CATEGORIES).
  # held: why it waits for Data Quality rather than being approved in bulk
  # (held_reason), or nil.
  Item = Data.define(:candidate_id, :kind, :status, :claim, :payload, :quote, :source, :notes,
    :ai_recommendation, :ai_reason, :ai_confidence, :ai_model, :ai_checked_at, :verify_run_id,
    :subject_type, :subject_id, :record, :differences, :found_by, :crawl_run_id, :category, :held,
    :dq_recommendation, :dq_reason) do
    # dq_*: Data Quality's call and reason (#306), nil when it made none or
    # the claim changed (or was reopened) since.
    def initialize(dq_recommendation: nil, dq_reason: nil, **) = super
  end
  Source = Data.define(:id, :url, :title, :source_kind)
  EvidenceItem = Data.define(:source, :quote, :found_by, :confidence)
  PendingFact = Data.define(:type, :id, :kind, :attributes, :evidence, :created_at, :last_event)
  # One directory fact as the admin shows it. values: its stored values;
  # history: Directory::VerificationEventRefs, newest first; published: public
  # on the site now (#104's rules).
  Fact = Data.define(:type, :id, :name, :verification_status, :verified_by, :verified_at, :values, :history, :published)

  QUEUES = {
    recommended: -> { Candidate.recommended },
    needs_review: -> { Candidate.status_needs_review }
  }.freeze
  # Link ends were resolved by match; editing them (by name or by id) means
  # matching again. Moving a published link isn't an edit either.
  LINK_ENDS = %w[organization facility from_organization to_organization
    organization_id facility_id from_organization_id to_organization_id].freeze
  # A link's type is part of which link it is, and a plant's parent site is
  # its place in the hierarchy: changing either means matching again.
  NOT_EDITABLE = (LINK_ENDS + %w[id slug relationship_type parent_id]).freeze
  # What reasons() calls candidates with no notes.
  NO_REASON = "no reason"
  # The Checks screen's groups of waiting items (#201). Pending facts with no
  # candidate are in "facts" too.
  CATEGORIES = %w[changed links facts duplicates].freeze
  # A link between companies, or a company and a plant (a role or technology is a fact).
  CHECK_LINK_KINDS = %w[relationship facility_relationship].freeze
  # Match's notes when a name is close to a record it might be.
  DUPLICATE_NOTES = [ "but similar:", "could be the same brand" ].freeze
  # A company's role or technology is what that fact is (a plant's
  # technology is an ordinary value).
  IDENTIFYING = { "organization_role" => %w[role], "organization_technology" => %w[technology],
    # A deal term is the same one only by its link, type and external ID (DATA.md).
    "deal_term" => %w[link_type term_type external_id] }.freeze

  # The hold Data Quality's review lifts (#306): a source's first batch.
  FIRST_BATCH = "it's from this source's first batch".freeze
  # A deal term (an award, a round) is never approved in bulk or in a safe
  # class (PM, 18 Oct): a person decides it, or accepts Data Quality's call on it.
  BY_A_PERSON = "a deal term is decided by a person".freeze
  # The holds a person's Accept of Data Quality's reviewed list lifts.
  REVIEWED_HOLDS = [ FIRST_BATCH, BY_A_PERSON ].freeze
  # A decision that collided with a merge of the same records (#325).
  BUSY = "someone was merging this just then; try again".freeze

  class << self
    # "human:<who>": a nonblank name, so the audit trail says who decided.
    def human!(by)
      raise ArgumentError, "only a human decides (by: \"human:…\")" unless by.to_s.match?(/\Ahuman:\S+\z/)
    end

    # Candidates waiting for a decision, oldest first. queue: :recommended
    # (the agent recommends publishing) or :needs_review. Narrow by the
    # verify run, and by reason (the start of the note, e.g. "human-verified").
    def candidates(queue: :recommended, run_id: nil, reason: nil, after_id: nil, limit: 50,
      directory: DataQuality::DirectoryClient.new)
      scope = queue_scope(queue, run_id:, reason:).includes(:source, :crawl_run).order(:id).limit(limit)
      scope = scope.where("candidates.id > ?", after_id) if after_id
      scope.map { |candidate| item(candidate, directory) }
    end

    # Every candidate id in a queue with the same filters as candidates(),
    # oldest first: what "Approve all" approves (#188).
    def candidate_ids(queue: :recommended, run_id: nil, reason: nil)
      queue_scope(queue, run_id:, reason:).order(:id).pluck(:id)
    end

    # One candidate as the admin shows it, whatever its status, or nil.
    def candidate(id, directory: DataQuality::DirectoryClient.new)
      found = Candidate.includes(:source, :crawl_run).find_by(id:)
      found && item(found, directory)
    end

    # The kinds of directory fact, for pending_facts(kind:).
    def fact_kinds(directory: DataQuality::DirectoryClient.new) = directory.fact_kinds

    # How many candidates wait in each queue: { recommended: 12, needs_review: 3 }.
    def counts = QUEUES.transform_values { |scope| scope.call.count }

    # Waiting candidates in a Checks group ("all" or one of CATEGORIES),
    # oldest first, optionally from one kind of source. Pending facts are
    # listed by pending_facts.
    def checks(category: "all", source_kind: nil, after_id: nil, limit: 50, directory: DataQuality::DirectoryClient.new)
      scope = category_scope(category, source_kind:).includes(:source, :crawl_run).order(:id).limit(limit)
      scope = scope.where("candidates.id > ?", after_id) if after_id
      scope.map { |candidate| item(candidate, directory) }
    end

    # The recommended claims a Checks filter shows, oldest first: what
    # "Approve N safe" counts, fingerprints and approves on that filter.
    # Only truly safe ones: a claim that waits for Data Quality (held_reason)
    # is never approved in bulk, however it's recommended.
    def safe_ids(category: "all", source_kind: nil, directory: DataQuality::DirectoryClient.new)
      firsts = first_batches
      claims = category_scope(category, source_kind:).where(id: Candidate.recommended.select(:id)).includes(:source).order(:id).to_a
      # Which attached records a person decided, one query per kind of record.
      decided = claims.select(&:subject_id).group_by(&:subject_type).flat_map do |type, group|
        directory.human_decided_ids(type:, ids: group.map(&:subject_id)).map { |id| [ type, id ] }
      end.to_set
      claims.reject { |candidate| held_reason(candidate, directory:, firsts:, decided: decided.include?([ candidate.subject_type, candidate.subject_id ])) }
        .map(&:id)
    end

    # Why a claim waits for Data Quality instead of being approved in bulk
    # (Tosin, 16 Oct, after an approve-all replaced hand-written descriptions):
    # - its record is one a person decided, so approving would change a value
    #   they chose; it's decided one at a time (Keep ours or Take theirs)
    # - it came in its source's first batch, which Data Quality reviews
    # - it isn't attached to a record yet: approving could find a record a
    #   person decided by its name and change it
    # nil when it's safe. decided: whether a person decided its record, when already known.
    def held_reason(candidate, directory: DataQuality::DirectoryClient.new, record: :lookup, firsts: first_batches, decided: nil)
      return "it isn't attached to a record yet" unless candidate.subject_id

      if decided.nil?
        record = directory.attached_record(candidate) if record == :lookup
        # Any decision a person made: approved, rejected or taken off.
        decided = record&.verified_by.to_s.start_with?("human:")
      end
      return "it would change a record a person decided" if decided || candidate.notes.to_s.match?(/\Ahuman-verified /i)
      return BY_A_PERSON if candidate.kind_deal_term?
      return FIRST_BATCH if candidate.crawl_run_id && firsts[candidate.source.source_kind] == candidate.crawl_run_id

      nil
    end

    # Each kind of source's first batch: { "usaspending_doe_awards" => crawl run id }.
    def first_batches
      Candidate.joins(:source).where.not(crawl_run_id: nil).group("sources.source_kind").minimum(:crawl_run_id)
    end

    # The claims waiting on one fact (both queues), oldest first, for its
    # page's decision panel.
    def waiting_for(type:, id:, directory: DataQuality::DirectoryClient.new)
      waiting_scope.where(subject_type: type.to_s, subject_id: id).includes(:source, :crawl_run).order(:id)
        .map { |candidate| item(candidate, directory) }
    end

    # How many claims wait on each of these facts, and the first, counted as
    # waiting_for counts them: { id => [count, first_candidate_id] }.
    def waiting_counts(type:, ids:)
      waiting_scope.where(subject_type: type.to_s, subject_id: ids).group(:subject_id)
        .pluck(:subject_id, Arel.sql("COUNT(*)"), Arel.sql("MIN(candidates.id)")).to_h { |id, count, first| [ id, [ count, first ] ] }
    end

    # The last decision a person made on a claim about one fact, for the
    # result line once nothing waits: { status: "merged"|"rejected", by:, at: }, or nil.
    def last_decision_for(type:, id:)
      candidate = Candidate.where(subject_type: type.to_s, subject_id: id, status: %w[merged rejected])
        .where.not(reviewed_at: nil).order(reviewed_at: :desc).first
      candidate && { status: candidate.status, by: candidate.reviewed_by, at: candidate.reviewed_at }
    end

    # How one claim was decided, for its page's result line: { status:, by:, at: }, or nil.
    def decision_of(candidate_id)
      candidate = Candidate.where(id: candidate_id, status: %w[merged rejected]).where.not(reviewed_at: nil).first
      candidate && { status: candidate.status, by: candidate.reviewed_by, at: candidate.reviewed_at }
    end

    # Whether a fact has any source, so it can be approved.
    def sourced?(type:, id:, directory: DataQuality::DirectoryClient.new) = directory.sourced?(type: type.to_s, id:)

    # Ids of the claims a Checks filter lists, in its order (oldest first).
    def check_ids(category: "all", source_kind: nil) = category_scope(category, source_kind:).order(:id).pluck(:id)

    # The claims a Checks filter lists, in its order, as [type, id] of the
    # fact each is attached to (nil for a claim not attached yet): for Prev
    # and Next on a fact page opened from Checks.
    # Pending facts with no open claim follow, kind by kind, as Checks lists
    # them (All and Facts, without a source filter).
    def check_subjects(category: "all", source_kind: nil, directory: DataQuality::DirectoryClient.new)
      # [type, id, claim id] per claim row (one fact can have several), then [type, id, nil] per pending fact.
      claims = category_scope(category, source_kind:).where.not(subject_id: nil).order(:id).pluck(:subject_type, :subject_id, :id)
      return claims if source_kind || !%w[all facts].include?(category)

      open = Candidate.where(status: %w[new matched needs_review]).where.not(subject_id: nil).pluck(:subject_type, :subject_id).to_set
      pending = directory.fact_kinds.flat_map do |kind|
        directory.pending_fact_ids(kind:).sort.map { |id| [ kind.camelize, id ] }.reject { |subject| open.include?(subject) }.map { |subject| [ *subject, nil ] }
      end
      claims + pending
    end

    # Whether any claim on a fact is still open (new, matched or needing
    # review), recommended or not: then the fact is decided through it.
    def open_claims?(type:, id:) = Candidate.where(status: %w[new matched needs_review], subject_type: type.to_s, subject_id: id).exists?

    # How many candidates wait in each Checks group, plus "all":
    # { "all" => 9, "changed" => 2, … }. Pending facts aren't included.
    def check_counts(source_kind: nil)
      CATEGORIES.index_with { |category| category_scope(category, source_kind:).count }.then { |counts| { "all" => counts.values.sum }.merge(counts) }
    end

    # Kinds of question in a queue, most common first, quoted names blanked
    # ('no exact match for "…"'), for the admin's reason filter: passing one
    # back as candidates(reason:) lists that group.
    def reasons(queue: :needs_review, run_id: nil)
      scope = QUEUES.fetch(queue.to_sym).call
      scope = scope.where(verify_run_id: run_id) if run_id
      scope.pluck(:notes).map { |notes| reason_of(notes) }
        .tally.sort_by { |reason, n| [ -n, reason ] }
    end

    # Publishes each candidate as a fact verified by `by`, with its quote as
    # evidence (the verifier's confidence, the verify run) and the candidate
    # and run in the audit trail. A human's write isn't protected, so a
    # candidate that disagrees with a human-verified value applies the new
    # value; the admin shows `differences` first. An approved unit fills its
    # site's blank fields. Already-decided candidates are refused.
    # only_recommended: true for bulk approval, which covers the Recommended
    # queue only; anything else needs a look on its own (#86).
    # One outer transaction: an unexpected error rolls the whole batch back
    # (a refused item is a Result with errors, not an error).
    #
    # data_quality_reviewed: Data Quality recommended these (#306), which
    # lifts the first-batch hold and only that one.
    #
    # A merge locks the same rows (#325): if the two collide, the database
    # stops one, and here nothing is approved; each claim comes back with
    # BUSY, to try again.
    #
    # safe_check (a safe class, DataQuality::SafeClasses): asked under the
    # record's lock in place of the usual holds; its answer is why the claim
    # isn't safe, or nil.
    def approve(candidate_ids, by:, reason: nil, only_recommended: false, data_quality_reviewed: false, safe_check: nil,
      directory: DataQuality::DirectoryClient.new)
      human!(by)
      firsts = first_batches if only_recommended # once per bulk approval
      Candidate.transaction do
        Candidate.where(id: candidate_ids).includes(:crawl_run, :verify_run).order(:id).map do |candidate|
          approve_one(candidate, by:, reason:, directory:, only_recommended:, firsts:, data_quality_reviewed:, safe_check:)
        end
      end
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      candidate_ids.map { |id| Result.new(candidate_id: id, ref: nil, errors: [ BUSY ]) }
    end

    # Changes some of a candidate's values, then approves it. Link ends and
    # slug can't be edited here.
    def edit_and_approve(candidate_id, attributes:, by:, reason: nil, directory: DataQuality::DirectoryClient.new)
      human!(by)
      candidate = Candidate.find_by(id: candidate_id) or return gone(candidate_id)
      attributes = attributes.to_h.stringify_keys
      if (locked = attributes.keys & locked_keys(candidate.kind)).any?
        return Result.new(candidate_id:, ref: nil, errors: [ "can't edit #{locked.to_sentence} here" ])
      end

      result = nil
      Candidate.transaction do
        lock_for_decision(candidate) # before the edit, in the same order as everywhere else
        edited = attributes.any? { |name, value| candidate.payload[name] != value }
        candidate.update!(payload: candidate.payload.merge(attributes))
        # The verifier checked the claim as found, not as edited: no confidence carries over.
        result = approve_one(candidate, by:, reason:, directory:, edited:)
        raise ActiveRecord::Rollback unless result.ok? # keep the original values if publishing failed
      end
      result
    end

    # Closes open candidates whose source just restates a fact a person
    # already decided (#240), the outcome match now gives them on its own,
    # recorded as the named person. Approving them instead would add an
    # identical "verified again" event to every fact's history. Nothing is
    # written to the directory except the source's evidence on each fact
    # being stamped as checked. candidate_ids: nil for every open candidate
    # attached to a fact. dry_run: everything is rolled back. Returns one
    # Result per candidate looked at; errors say why one stays open.
    def confirm_identical(candidate_ids = nil, by:, dry_run: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      # A "dropped" flag says the source no longer lists the fact; it repeats
      # the fact's last payload, so it would always look identical.
      scope = Candidate.where(status: %w[new matched needs_review]).where.not(subject_id: nil)
        .where("review_origin IS DISTINCT FROM 'dropped'").order(:id)
      scope = scope.where(id: candidate_ids) if candidate_ids
      results = []
      Candidate.transaction(requires_new: true) do
        scope.each do |candidate|
          lock_for_decision(candidate)
          results << confirm_one(candidate, by:, directory:)
        end
        raise ActiveRecord::Rollback if dry_run
      end
      results
    end

    # Reopens rejected candidates (#228): each goes back to new, unattached
    # and with no AI verdict, so the next match and verify runs decide it
    # afresh and it comes back to the review queue. Who reopened it, when and
    # why are appended to its reopenings, with the rejection it undid.
    # Re-extracting its source keeps it (Stages::Extract). One that proposed
    # its record, or whose record was rejected or taken down, can't be
    # reopened here.
    def reopen(candidate_ids, by:, reason:, directory: DataQuality::DirectoryClient.new)
      human!(by)
      raise ArgumentError, "say why it's reopened" if reason.blank?

      Candidate.where(id: candidate_ids).order(:id).map do |candidate|
        Candidate.transaction do
          candidate.lock!
          next Result.new(candidate_id: candidate.id, ref: nil, errors: [ "it isn't rejected" ]) unless candidate.status_rejected?
          # A proposal is retired when its last candidate is rejected, whichever
          # one proposed it; match would only send it back to review as closed.
          if candidate.proposed_subject || (candidate.subject_id && directory.fact(type: candidate.subject_type, id: candidate.subject_id)&.closed?)
            next Result.new(candidate_id: candidate.id, ref: nil,
              errors: [ "the record it was attached to was rejected or taken down; decide that record first" ])
          end

          # Appended, so the match notes and review decisions that follow don't
          # erase it. The rejection it undoes goes with it.
          reopening = { "by" => by, "at" => Time.current.iso8601, "reason" => reason,
            "rejected_by" => candidate.reviewed_by, "rejection" => candidate.notes }
          candidate.update!(status: "new", subject_type: nil, subject_id: nil, review_origin: nil, notes: "Reopened: #{reason}",
            reopenings: candidate.reopenings + [ reopening ], reviewed_by: nil, reviewed_at: nil, ai_recommendation: nil, ai_reason: nil, ai_confidence: nil,
            ai_model: nil, ai_checked_at: nil, verify_run_id: nil, ai_source_sha256: nil)
          Result.new(candidate_id: candidate.id, ref: nil, errors: [])
        end
      end
    end

    # Rejects candidates. A record match created only for one of them (a
    # proposal) is rejected too, unless another live candidate is attached.
    def reject(candidate_ids, by:, reason: nil, directory: DataQuality::DirectoryClient.new)
      human!(by)
      Candidate.where(id: candidate_ids).order(:id).map do |candidate|
        errors = []
        Candidate.transaction do
          candidate.lock! # an approval at the same moment waits, then sees the decision
          next Result.new(candidate_id: candidate.id, ref: nil, errors: [ already(candidate) ]) unless open?(candidate)

          candidate.update!(status: "rejected", notes: reason.presence || candidate.notes, reviewed_by: by, reviewed_at: Time.current)
          errors = retire_proposal(candidate, by:, reason:, directory:)
          # The proposal couldn't be retired: undo the rejection too, so a retry works.
          raise ActiveRecord::Rollback if errors.any?

          Result.new(candidate_id: candidate.id, ref: nil, errors: [])
        end || Result.new(candidate_id: candidate.id, ref: nil, errors:)
      end
    end

    # Directory facts of one kind waiting for a human with no open candidate
    # (those show in the candidate queues), e.g. seed facts loaded as pending.
    # Returns up to `limit`, reading past covered facts, so a full page means
    # there may be more (next page: after_id = the last one's id).
    def pending_facts(kind:, after_id: nil, limit: 50, directory: DataQuality::DirectoryClient.new)
      facts = []
      loop do
        page = directory.pending_facts(kind:, after_id:, limit:)
        open = Candidate.where(status: %w[new matched needs_review], subject_type: page.map(&:type).uniq,
          subject_id: page.map(&:id)).pluck(:subject_type, :subject_id).to_set
        facts.concat(page.reject { |fact| open.include?([ fact.type, fact.id ]) })
        break if facts.size >= limit || page.size < limit

        after_id = page.last.id
      end
      facts = facts.first(limit)
      sources = sources_by_id(facts.flat_map { |fact| fact.evidence.map(&:source_id) })

      facts.map do |fact|
        PendingFact.new(type: fact.type, id: fact.id, kind: fact.kind, attributes: fact.attributes, created_at: fact.created_at,
          last_event: fact.last_event, evidence: fact.evidence.map { |e| EvidenceItem.new(source: sources[e.source_id], quote: e.quote,
            found_by: e.found_by, confidence: e.confidence) })
      end
    end

    # How many facts pending_facts lists, across every kind: pending, with no
    # open candidate (those are counted in the queues).
    def pending_count(directory: DataQuality::DirectoryClient.new)
      directory.fact_kinds.sum do |kind|
        ids = directory.pending_fact_ids(kind:)
        next 0 if ids.empty?

        covered = Candidate.where(status: %w[new matched needs_review], subject_type: kind.camelize, subject_id: ids).distinct.count(:subject_id)
        ids.size - covered
      end
    end

    # Approves (or republishes) a directory fact, optionally with edited
    # values; the edit is recorded in its history.
    # A fact with no source isn't published (VOICE.md: if we can't source it,
    # we don't publish it).
    def approve_fact(type:, id:, by:, reason: nil, attributes: {}, directory: DataQuality::DirectoryClient.new)
      decide_fact(type, id, "verified", by:, reason:, attributes:, directory:, require_source: true)
    end

    # Put back: the status it had before it was taken off. A record that was
    # pending (a site public through a verified unit) goes back to pending,
    # its own fields still unapproved; anything else is approved again.
    # Only while it's still taken off, so an old form can't undo a newer decision.
    def republish(type:, id:, by:, reason: nil, directory: DataQuality::DirectoryClient.new)
      now = directory.fact(type:, id:)&.verification_status
      return Result.new(candidate_id: nil, ref: nil, errors: [ "it's #{now || 'gone'} now, so it wasn't changed" ]) unless now == "unpublished"

      before = directory.verification_history(type:, id:).find { |event| event.to_status == "unpublished" }&.from_status
      return decide_fact(type, id, "pending", by:, reason:, directory:) if before == "pending"

      approve_fact(type:, id:, by:, reason:, directory:)
    end

    def reject_fact(type:, id:, by:, reason: nil, directory: DataQuality::DirectoryClient.new)
      decide_fact(type, id, "rejected", by:, reason:, directory:)
    end

    # Takes a published fact down: hidden from the public site, recorded as
    # unpublished by `by`, protected from the pipeline. Republish = approve_fact.
    def unpublish(type:, id:, by:, reason: nil, directory: DataQuality::DirectoryClient.new)
      decide_fact(type, id, "unpublished", by:, reason:, directory:)
    end

    def history(type:, id:, directory: DataQuality::DirectoryClient.new) = directory.verification_history(type:, id:)

    # Changing a plant's status (#316), the admin's side of
    # `directory:set_status`: what it would change, read only, and then the
    # change as `by`'s decision. The evidence is a source and its quote: a
    # link, saved as a source, or NRC's status file by its source_id. Each returns a
    # DirectoryClient::StatusResult.
    def status_change_plan(ids:, status:, directory: DataQuality::DirectoryClient.new) = directory.status_change_plan(ids:, status:)

    def set_status(ids:, status:, by:, reason:, source_url: nil, source_id: nil, quote: nil, directory: DataQuality::DirectoryClient.new)
      if source_url.present?
        source = DataQuality::Sources.find_or_create(url: source_url.strip)
        return DataQuality::DirectoryClient::StatusResult.new(plan: nil, error: "Enter a link to a public source, starting with https://") unless source.ok?

        source_id = source.ref.id
      end
      directory.set_status(ids:, status:, by:, reason:, source_id:, quote: quote.presence)
    end

    def nrc_status_quote(name, directory: DataQuality::DirectoryClient.new) = directory.nrc_status_quote(name)

    # Merges a company or plant site into another, as a person's decision
    # (#142): a reason is required; dry_run says what would move and changes
    # nothing. Returns a MergeResult, never raises.
    def merge(type:, from_id:, into_id:, by:, reason:, dry_run: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      return MergeResult.new(errors: [ "pick the record to merge it into" ], moved: nil) unless into_id
      return MergeResult.new(errors: [ "say why they're the same" ], moved: nil) if reason.blank? && !dry_run

      result, moved = directory.merge(type, from_id:, into_id:, by:, reason: reason.presence, dry_run:)
      MergeResult.new(errors: result.errors, moved:)
    end

    # A fact with its decision, values and history, or nil.
    def fact(type:, id:, directory: DataQuality::DirectoryClient.new)
      record = directory.fact(type:, id:) or return
      Fact.new(type: record.type, id: record.id, name: record.name, verification_status: record.verification_status,
        verified_by: record.verified_by, verified_at: record.verified_at, values: record.values || {},
        history: directory.verification_history(type: record.type, id: record.id),
        published: directory.published?(type: record.type, id: record.id))
    end

    private
      # Evidence confidence means "how sure the source supports this". The
      # verifier's confidence only says that when it recommended publishing;
      # for a review verdict (disputed, unsure) it's confidence in that
      # verdict, so the evidence gets none.
      def supporting_confidence(candidate)
        candidate.ai_confidence if candidate.ai_recommendation == "recommend_publish"
      end

      def gone(candidate_id)
        Result.new(candidate_id:, ref: nil, errors: [ "this claim no longer exists; refresh the queue" ])
      end

      def open?(candidate) = candidate.status_new? || candidate.status_matched? || candidate.status_needs_review?

      # A recommendation made against an earlier snapshot of its source.
      def lapsed?(candidate)
        candidate.ai_recommendation == "recommend_publish" && candidate.ai_source_sha256 != candidate.source.reload.content_sha256
      end
      def already(candidate) = "it's already #{candidate.status.humanize(capitalize: false)}"

      # Locked, and in one transaction with the directory write: two people
      # approving at once publish once, and a crash can't leave a published
      # fact still waiting for approval.
      # only_recommended (bulk approval): checked under the lock, so a claim a
      # verify run moved to review a moment ago isn't published in bulk.
      def approve_one(candidate, by:, reason:, directory:, edited: false, only_recommended: false, firsts: nil, data_quality_reviewed: false,
        safe_check: nil)
        Candidate.transaction do
          lock_for_decision(candidate)
          next Result.new(candidate_id: candidate.id, ref: nil, errors: [ already(candidate) ]) unless open?(candidate)
          if only_recommended && !(candidate.ai_recommendation == "recommend_publish" && !candidate.status_needs_review?)
            next Result.new(candidate_id: candidate.id, ref: nil, errors: [ "it isn't recommended, so approve it on its own" ])
          end
          # Checked again when a bulk approval runs: the record may have been
          # decided since the page loaded. Its row stays locked through the
          # write, so a person's approval can't land in between.
          directory.lock_fact(type: candidate.subject_type, id: candidate.subject_id) if only_recommended && candidate.subject_id
          held =
            if safe_check then safe_check.call(candidate)
            elsif only_recommended then held_reason(candidate, directory:, firsts: firsts || first_batches)
            end
          held = nil if data_quality_reviewed && REVIEWED_HOLDS.include?(held)
          if held
            why = safe_check ? "it's no longer safe: #{held}" : "it waits for Data Quality: #{held}"
            next Result.new(candidate_id: candidate.id, ref: nil, errors: [ why ])
          end
          # A link is written onto the record match attached, which needs both
          # ends found. One whose company or plant is still a question has no
          # link yet; without this check the write would find any link of the
          # same type and add the quote to it.
          if DataQuality::DirectoryClient::LINK_KINDS.include?(candidate.kind) && candidate.subject_id.nil?
            next Result.new(candidate_id: candidate.id, ref: nil,
              errors: [ "its company or plant isn't settled yet; decide that, and the next match run links it" ])
          end
          if lapsed?(candidate)
            next Result.new(candidate_id: candidate.id, ref: nil,
              errors: [ "its source changed after the verifier checked it; the next verify run checks it again" ])
          end

          # The evidence belongs to the run that judged it (verify), else the one that found it.
          run = candidate.verify_run || candidate.crawl_run
          confidence = edited ? nil : supporting_confidence(candidate)
          result = directory.write_fact(candidate, confidence:, crawl_run: run, by:, reason:, edited:)
          next Result.new(candidate_id: candidate.id, ref: nil, errors: result.errors) unless result.success?

          candidate.update!(status: "merged", subject_type: result.ref.type, subject_id: result.ref.id,
            reviewed_by: by, reviewed_at: Time.current)
          fill_site(candidate, result.ref.id, run, directory) if candidate.kind_facility?
          Result.new(candidate_id: candidate.id, ref: result.ref, errors: [])
        end
      end

      # The ILIKE pattern for a reason from reasons(): its start, with each
      # blanked name ("…") matching any name.
      # Match notes about a link's end start with that end ("organization: no
      # exact match for …"); the reason is what follows.
      NOTE_PREFIXES = %w[organization facility from_organization to_organization].freeze

      def reason_of(notes)
        text = notes.to_s.sub(/\A(?:#{NOTE_PREFIXES.join('|')}): /, "")
        text.split(":").first.to_s.gsub(/"[^"]*"/, '"…"').squish.presence || NO_REASON
      end

      # ILIKE patterns for a reason from reasons(): its start, with or without
      # a link end's prefix, each blanked name ("…") matching any name.
      def reason_patterns(reason)
        pattern = "#{Candidate.sanitize_sql_like(reason).gsub('"…"', '"%"')}%"
        [ pattern ] + NOTE_PREFIXES.map { |prefix| "#{prefix}: #{pattern}" }
      end

      # A published unit completes its site's missing details (see
      # DirectoryClient#fill_site_from_unit). The unit stays published if the
      # site refuses (a human rejected it); the candidate notes why.
      def fill_site(candidate, unit_id, run, directory)
        filled = directory.fill_site_from_unit(unit_id, candidate, crawl_run: run)
        return if filled.nil? || filled.success?

        # A conflict (e.g. NRC's state is a nearby city's) is shown, not applied.
        why = filled.conflict? ? "Its site disagrees, so it wasn't filled" : "Site not filled"
        candidate.update!(notes: [ candidate.notes, "#{why}: #{filled.errors.join('; ')}" ].compact_blank.join(". "))
      end

      # Returns errors from rejecting the proposal, or [].
      def retire_proposal(candidate, by:, reason:, directory:)
        return [] unless candidate.subject_id

        errors = []
        # Under the proposal's lock, so two rejections at once can't each see
        # the other as still live and leave the proposal behind. Already
        # closed: nothing to retire.
        directory.unless_closed(candidate) do
          attached = Candidate.where(subject_type: candidate.subject_type, subject_id: candidate.subject_id)
          next unless attached.where(proposed_subject: true).exists?
          next if attached.where.not(id: candidate.id).where(status: %w[new matched merged needs_review]).exists?

          errors = directory.decide_fact(candidate.subject_type.underscore, id: candidate.subject_id, status: "rejected", by:,
            reason:, context: { "candidate_id" => candidate.id }).errors
        end
        errors
      end

      # The source, then the candidate (extract's order, so no deadlock): a new
      # snapshot can't land between the lapsed? check and the write.
      def confirm_one(candidate, by:, directory:)
        fail_with = ->(why) { Result.new(candidate_id: candidate.id, ref: nil, errors: [ why ]) }
        return fail_with.call(already(candidate)) unless open?(candidate)

        record = directory.attached_record(candidate) or return fail_with.call("its fact no longer exists")
        return fail_with.call("#{record.name} isn't decided yet, so a person reviews it") if record.verification_status == "pending"
        if candidate.source.status_reason.present?
          return fail_with.call("its source's last fetch failed (#{candidate.source.status_reason}); run this after a good read")
        end

        confirmation = directory.confirm(candidate, in_source: in_source(candidate))
        case confirmation&.outcome
        when :confirmed
          kept = confirmation.overruled.map { |name, (stored, stated)| "#{name.humanize(capitalize: false)} #{stored} (it says #{stated})" }
          note = "Confirmed by #{by}: identical to #{record.name} as decided"
          note += ", except where a person's decision stands: #{kept.join('; ')}" if kept.any?
          candidate.update!(status: "confirmed", notes: note, reviewed_by: by, reviewed_at: Time.current)
          Result.new(candidate_id: candidate.id, ref: record.ref, errors: [])
        when :different
          what = confirmation.differences.map { |name, (stored, stated)| "#{name.humanize(capitalize: false)} #{stored.presence || 'blank'} → #{stated}" }
          fail_with.call("it differs: #{[ *what, *confirmation.errors ].join('; ')}")
        when :unsourced then fail_with.call("the same values, but #{record.name} has no evidence from this source yet")
        else fail_with.call("its fact no longer exists")
        end
      end

      # Whether the candidate's source still contains a quote, as its plug-in
      # checks it; nil (only the claim's own quote counts) without a plug-in.
      def in_source(candidate)
        plugin = DataQuality::Plugin.for(candidate.source.source_kind)
        ->(quote) { plugin.quote_in_source?(candidate.source, quote) }
      rescue DataQuality::Plugin::UnknownSourceKind
        nil
      end

      def lock_for_decision(candidate)
        ::Source.lock.find(candidate.source_id)
        candidate.lock!
      end

      # A reason from reasons(), back to its candidates; NO_REASON means no notes.
      def queue_scope(queue, run_id:, reason:)
        scope = QUEUES.fetch(queue.to_sym).call
        scope = scope.where(verify_run_id: run_id) if run_id
        scope = filter_by_reason(scope, reason) if reason.present?
        scope
      end

      def filter_by_reason(scope, reason)
        return scope.where(notes: [ nil, "" ]) if reason == NO_REASON

        scope.where("candidates.notes ILIKE ANY (ARRAY[?])", reason_patterns(reason))
      end

      def decide_fact(type, id, status, by:, reason:, attributes: {}, directory:, require_source: false)
        human!(by)
        if (locked = attributes.to_h.stringify_keys.keys & locked_keys(type.to_s.underscore)).any?
          return Result.new(candidate_id: nil, ref: nil, errors: [ "can't edit #{locked.to_sentence} here" ])
        end
        if require_source && !directory.sourced?(type: type.to_s.camelize, id:)
          return Result.new(candidate_id: nil, ref: nil, errors: [ "it has no source; add one before publishing it" ])
        end

        result = directory.decide_fact(type.to_s.underscore, id:, status:, by:, reason:, attributes:)
        Result.new(candidate_id: nil, ref: result.ref, errors: result.errors)
      end

      # Keys an edit may not change for this kind of fact.
      def locked_keys(kind) = NOT_EDITABLE + IDENTIFYING.fetch(kind.to_s, [])

      def item(candidate, directory)
        record = directory.attached_record(candidate)
        differences = DataQuality::Differences.with_human_verified(candidate, record)
        Item.new(candidate_id: candidate.id, kind: candidate.kind, status: candidate.status, claim: DataQuality::Claim.describe(candidate),
          payload: candidate.payload, quote: candidate.quote, notes: candidate.notes,
          source: Source.new(id: candidate.source.id, url: candidate.source.url, title: candidate.source.title, source_kind: candidate.source.source_kind),
          ai_recommendation: candidate.ai_recommendation, ai_reason: candidate.ai_reason, ai_confidence: candidate.ai_confidence,
          ai_model: candidate.ai_model, ai_checked_at: candidate.ai_checked_at, verify_run_id: candidate.verify_run_id,
          subject_type: candidate.subject_type, subject_id: candidate.subject_id, record:, differences:,
          found_by: candidate.crawl_run&.model, crawl_run_id: candidate.crawl_run_id, category: category_of(candidate),
          held: held_reason(candidate, directory:, record:), **(DataQuality::Recommendations.current?(candidate) ? { dq_recommendation: candidate.dq_recommendation, dq_reason: candidate.dq_reason } : {}))
      end

      # The same rules as category_scope, for one candidate.
      def category_of(candidate)
        notes = candidate.notes.to_s
        if notes.match?(/\Ahuman-verified /i) then "changed"
        elsif DUPLICATE_NOTES.any? { |note| notes.downcase.include?(note) } then "duplicates"
        elsif CHECK_LINK_KINDS.include?(candidate.kind) then "links"
        else "facts"
        end
      end

      # Waiting candidates in one of the Checks screen's groups. A candidate is
      # in exactly one: a disagreement with a human-verified value (verify's
      # note), then a possible duplicate (match's note), then a link, else a fact.
      def category_scope(category, source_kind: nil)
        scope = waiting_scope
        scope = scope.where(source_id: ::Source.where(source_kind:).select(:id)) if source_kind
        notes = "COALESCE(candidates.notes, '')"
        changed = "#{notes} ILIKE 'human-verified %'"
        duplicate = "(#{DUPLICATE_NOTES.map { |note| "#{notes} ILIKE #{Candidate.connection.quote("%#{note}%")}" }.join(' OR ')})"
        case category
        when nil, "all" then scope
        when "changed" then scope.where(changed)
        when "duplicates" then scope.where("#{duplicate} AND NOT (#{changed})")
        when "links" then scope.where(kind: CHECK_LINK_KINDS).where("NOT (#{changed}) AND NOT #{duplicate}")
        when "facts" then scope.where.not(kind: CHECK_LINK_KINDS).where("NOT (#{changed}) AND NOT #{duplicate}")
        else raise ArgumentError, "not a Checks group: #{category.inspect}"
        end
      end

      # Both queues: recommended, or needing a person's look.
      def waiting_scope = Candidate.where(id: Candidate.recommended.select(:id)).or(Candidate.status_needs_review)

      def sources_by_id(ids)
        ::Source.where(id: ids.uniq).to_h { |source| [ source.id, Source.new(id: source.id, url: source.url, title: source.title, source_kind: source.source_kind) ] }
      end
  end
end
