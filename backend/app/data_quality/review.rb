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
  # A record added by hand (#202): ref when it was written (or, in a dry
  # run, would be), errors, and the record of the same name if one exists.
  Added = Data.define(:ref, :errors, :existing) do
    def ok? = errors.empty?
  end
  ADDED_REASON = "Added by hand".freeze
  # Publishing a record (#202): how many of its approved facts go public
  # with it, and the facts added by hand with it that are still waiting
  # ([[type, id, name], …]).
  PublishPlan = Data.define(:goes_live_with, :added_with)
  # What a company's Add a fact can add (#202): its fact kind.
  COMPANY_FACTS = { "role" => :organization_role, "technology" => :organization_technology }.freeze
  # The verbs a link added by hand may use (#202 part 2b), in the admin's
  # words: company to company, and company to plant.
  COMPANY_LINK_VERBS = { "supplies" => "supplies", "invests_in" => "invests in", "funds" => "funds",
    "offtake_with" => "buys power from", "subsidiary_of" => "is a subsidiary of" }.freeze
  PLANT_LINK_VERBS = { "owns" => "owns", "operates" => "operates", "vendor_for" => "is the reactor developer for",
    "offtakes_from" => "buys power from" }.freeze
  # A link added by hand, as the preview says it: "Meta funds TerraPower".
  # from/to: [type, id, name].
  LinkPlan = Data.define(:from, :to, :verb, :share, :started_on, :ended_on) do
    def sentence = "#{from.last} #{verb} #{to.last}#{" (#{share.to_s.sub(/\.0+\z/, '')}%)" if share}"
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
  # A news item's about and mentions are what match found it's about (#137):
  # changed only by matching again, never edited in, like a link's ends.
  NOT_EDITABLE = (LINK_ENDS + %w[id slug relationship_type parent_id about mentions]).freeze
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
    # A deal term is the same one only by its link (and the company or link it
    # belongs to), type and external ID (DATA.md): an edit never moves a round.
    "deal_term" => %w[link_type link_id term_type external_id],
    # A news item's lead mark (#127) is what makes it a lead: the edit form can't change it.
    "news_item" => %w[lead] }.freeze
  # What a claim of this kind can't change when it's edited before approval:
  # its link's ends and type, and what identifies it (a role's role).
  def self.read_only_keys(kind) = NOT_EDITABLE + IDENTIFYING.fetch(kind.to_s, [])

  # The hold Data Quality's review lifts (#306): a source's first batch.
  FIRST_BATCH = "it's from this source's first batch".freeze
  # A deal term (an award, a round) is never approved in bulk or in a safe
  # class (PM, 18 Oct): a person decides it, or accepts Data Quality's call on it.
  BY_A_PERSON = "a deal term is decided by a person".freeze
  # The holds a person's Accept of Data Quality's reviewed list lifts.
  REVIEWED_HOLDS = [ FIRST_BATCH, BY_A_PERSON ].freeze
  # A trade-press item (#127): a pointer for Data Quality to the primary
  # source, never a claim to approve as it is. Nothing lifts it.
  LEAD = "it's a lead: Data Quality finds the primary source".freeze

  def self.lead?(candidate) = candidate.payload.is_a?(Hash) && candidate.payload["lead"] == true
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
      return LEAD if lead?(candidate)
      return "it isn't attached to a record yet" unless candidate.subject_id

      if decided.nil?
        record = directory.attached_record(candidate) if record == :lookup
        # Any decision a person made: approved, rejected or taken off.
        decided = record&.verified_by.to_s.start_with?("human:")
      end
      if (decided || candidate.notes.to_s.match?(/\Ahuman-verified /i)) && !evidence_only?(candidate, directory:)
        return "it would change a record a person decided"
      end
      return BY_A_PERSON if candidate.kind_deal_term?
      return FIRST_BATCH if candidate.crawl_run_id && firsts[candidate.source.source_kind] == candidate.crawl_run_id

      nil
    end

    # What a waiting claim is in Tosin's inbox (#548): "new_record" (a company
    # or plant to create), "new_fact" (a fact, link or deal to approve),
    # "change" (it would change something already there, shown old → new),
    # or "dq": Data Quality's to settle first (matching, Same as…, leads,
    # first batches, a source's own hold), never his.
    INBOX_KINDS = %w[new_record new_fact change dq].freeze

    # firsts: first_batches, passed in once for a whole list.
    def inbox_kind(candidate, directory: DataQuality::DirectoryClient.new, firsts: first_batches)
      return "dq" if lead?(candidate) || candidate.subject_id.nil? || open_company_ends(candidate).any?
      return "dq" if candidate.status_needs_review? && DataQuality::Recommendations.source_hold?(candidate)
      # Asked directly: a deal term's own hold would come first in held_reason.
      return "dq" if candidate.crawl_run_id && firsts[candidate.source.source_kind] == candidate.crawl_run_id
      # News is always a new fact about its company or plant.
      return "new_fact" if candidate.kind == "news_item"

      # A claim on a record not yet published (whichever claim proposed it)
      # is part of its first publication; Enrich's extra fields stay on Checks.
      pending = directory.fact(type: candidate.subject_type, id: candidate.subject_id)&.verification_status == "pending"
      if candidate.proposed_subject || pending
        return "dq" if candidate.payload.to_h.key?(DataQuality::DirectoryClient::ENRICHMENT_KEY) && !candidate.proposed_subject
        return %w[organization facility].include?(candidate.kind) ? "new_record" : "new_fact"
      end
      # A restatement, or only a new name for it (#548: name variants are
      # Data Quality's): no value changes, so never Tosin's.
      return "dq" if no_value_change?(candidate, directory:)

      "change"
    end

    # Approving it would only add its source as evidence on a published
    # record (PM, 24 Oct): no value differs from what's stored, and any name
    # or alias it gives is one the record already goes by. Such a claim joins
    # the agreed shortcut; anything that would change a value still asks.
    # Asked again under the record's lock when the shortcut runs.
    def evidence_only?(candidate, directory:)
      return false unless no_value_change?(candidate, directory:)

      payload = candidate.payload.to_h
      names = [ payload["name"], *Array(payload["aliases"]) ].compact_blank
      names.all? { |name| directory.known_name?(type: candidate.subject_type, id: candidate.subject_id, name:) }
    end

    # Approving it would change no stored or derived value of a published
    # record; at most it adds a name (an alias), which is Data Quality's (#548).
    def no_value_change?(candidate, directory:)
      record = directory.fact(type: candidate.subject_type, id: candidate.subject_id)
      return false unless record&.verification_status == "verified"

      changes = DataQuality::Differences.changes(candidate, record, directory:)
      return false if changes.nil? || changes.any?

      payload = candidate.payload.to_h
      # Values approval derives, not only the ones the claim states: a
      # website's domain, and a unit's site from its EIA plant ID.
      if candidate.kind == "organization" && payload["website"].present? && !payload.key?("domain")
        derived = directory.domain_from(payload["website"])
        return false if derived.present? && directory.organization(domain: derived)&.id != record.id
      end
      return false if candidate.kind == "facility" && directory.site_for_unit(candidate)

      true
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
    # These waiting candidates as Checks items, in the order given (Today's review, #373).
    def items(ids, directory: DataQuality::DirectoryClient.new)
      by_id = Candidate.where(id: ids).includes(:source, :crawl_run).index_by(&:id)
      ids.filter_map { |id| by_id[id] }.map { |candidate| item(candidate, directory) }
    end

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
    # Leads (#127) are Data Quality's work, not the admin's: listed, never counted.
    def check_counts(source_kind: nil)
      CATEGORIES.index_with { |category| category_scope(category, source_kind:).not_leads.count }.then { |counts| { "all" => counts.values.sum }.merge(counts) }
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
    # source_held: Data Quality reviewed a claim its source held for review
    # (Recommendations.source_hold?), so the checker's verdict isn't needed;
    # every other bulk check, a person's decision first, still applies.
    def approve(candidate_ids, by:, reason: nil, only_recommended: false, data_quality_reviewed: false, safe_check: nil,
      source_held: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      firsts = first_batches if only_recommended # once per bulk approval
      Candidate.transaction do
        Candidate.where(id: candidate_ids).includes(:crawl_run, :verify_run).order(:id).map do |candidate|
          approve_one(candidate, by:, reason:, directory:, only_recommended:, firsts:, data_quality_reviewed:, safe_check:, source_held:)
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
      return Result.new(candidate_id:, ref: nil, errors: [ LEAD ]) if lead?(candidate)

      attributes = attributes.to_h.stringify_keys
      # A field that can't be edited here may come back unchanged (the form
      # shows it); only a changed one is refused.
      locked, attributes = attributes.partition { |name, _| locked_keys(candidate.kind).include?(name) }.map(&:to_h)
      if (changed = locked.select { |name, value| candidate.payload[name] != value }.keys).any?
        return Result.new(candidate_id:, ref: nil, errors: [ "can't edit #{changed.to_sentence} here" ])
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

    # The company ends a waiting claim leaves as a question (#391): link ends
    # with no exact match, or a company claim with only similar names.
    # Returns [[end key or nil for the claim's own company, the name it gives]].
    def open_company_ends(candidate)
      return [] unless candidate.status.to_s == "needs_review" && candidate.subject_id.nil?

      if candidate.kind == "organization"
        return candidate.notes.to_s.include?("no exact match for") ? [ [ nil, candidate.payload["name"].to_s ] ] : []
      end
      ends = DataQuality::Stages::Match::LINK_ENDS.fetch(candidate.kind, {}).select { |_, type| type == :organization }.keys
      ends.filter_map do |key|
        # A malformed end (a string, not an object) is left for Reject, not a crash.
        named = candidate.payload[key]
        next unless named.is_a?(Hash)

        name = named["name"].to_s
        [ key, name ] if name.present? && candidate.notes.to_s.match?(/\A#{Regexp.escape(key)}(: no exact match for| ".*" isn't in the directory yet)/)
      end
    end

    # Settles one company end of a waiting claim as a person's decision
    # (#391): choice "same" (record_id is that company), "new" (a company
    # by the name it gives, not public yet) or "subsidiary" (that new
    # company, plus "subsidiary of" record_id, not public yet). The claim
    # then goes back to match and verify for its source (queued now), never
    # approved here. Returns a Result.
    def settle_company(candidate_id, end_key:, choice:, by:, record_id: nil, directory: DataQuality::DirectoryClient.new)
      human!(by)
      fail_with = ->(why) { Result.new(candidate_id:, ref: nil, errors: [ why ]) }
      result = nil
      # Matched and verified again by its source's plug-in (Research's too).
      source_kind = Candidate.joins(:source).where(id: candidate_id).pick("sources.source_kind")
      Candidate.transaction do
        candidate = Candidate.lock.find_by(id: candidate_id) or next result = fail_with.("it no longer exists")
        name = open_company_ends(candidate).to_h[end_key.presence] or next result = fail_with.("its company was settled already")
        other = (directory.fact(type: "Organization", id: record_id) if record_id.present?)
        if %w[same subsidiary].include?(choice) && !(other && %w[verified pending].include?(other.verification_status))
          next result = fail_with.("pick the company")
        end

        # The claim's name becomes another name of X (on approval); never one
        # that's already another company's name or other name (DQ's rule).
        if choice == "same" && (owner = directory.organization(name:)) && owner.id != other.id
          next result = fail_with.("“#{name}” is already #{owner.name}'s name or another name; pick #{owner.name}, or ask Data Quality")
        end

        company = if choice == "same" then other
        elsif %w[new subsidiary].include?(choice)
          made = directory.add_fact(:organization, { name: }, source_id: candidate.source_id, quote: candidate.quote, by:, reason: ADDED_REASON)
          unless made.success?
            taken = made.errors.join.match?(/already been taken/)
            next result = fail_with.(taken ? "a company named #{name} is in the directory already; pick it with Same as" : made.errors.to_sentence)
          end
          unless made.created
            # It found one by that name (its evidence was added): undone.
            result = fail_with.("a company named #{name} is in the directory already; pick it with Same as")
            raise ActiveRecord::Rollback
          end

          if choice == "subsidiary"
            link = directory.add_fact(:relationship, { from_organization_id: made.ref.id, to_organization_id: other.id, relationship_type: "subsidiary_of" },
              source_id: candidate.source_id, quote: candidate.quote, by:, reason: ADDED_REASON)
            unless link.success?
              result = fail_with.(link.errors.to_sentence)
              raise ActiveRecord::Rollback
            end
          end
          directory.fact(type: "Organization", id: made.ref.id)
        else next result = fail_with.("choose same as, new company or subsidiary")
        end

        what = { "same" => "the same as #{company.name}", "new" => "a new company", "subsidiary" => "a new company, a subsidiary of #{other&.name}" }.fetch(choice)
        note = "#{by.delete_prefix('human:')} settled #{name.inspect} as #{what}"
        if end_key.blank?
          # The claim's own company: attached to it, as match would.
          candidate.update!(status: "matched", subject_type: "Organization", subject_id: company.id, proposed_subject: false,
            notes: "#{note}. Was: #{candidate.notes}", ai_recommendation: nil, ai_reason: nil, ai_confidence: nil)
        else
          # A link end: named exactly as the company now, its own name kept
          # as another name, and matched again.
          payload = candidate.payload.deep_dup
          payload[end_key] = payload[end_key].merge("name" => company.name, "aliases" => [ *payload[end_key]["aliases"], (name unless name.casecmp?(company.name)) ].compact.uniq)
          candidate.update!(status: "new", payload:, notes: "#{note}. Was: #{candidate.notes}", ai_recommendation: nil, ai_reason: nil, ai_confidence: nil)
        end
        result = Result.new(candidate_id:, ref: company.ref, errors: [])
      end
      DataQuality::RunJob.perform_later(source_kind, only: %w[match verify]) if result&.ok?
      result
    end

    # Of these candidates, the ones that only restate a fact already on the
    # site as decided: what Close (confirm_identical) would close. A dry run,
    # so the label and the action agree. Returns a Set of ids.
    def restating_ids(candidate_ids, by:, directory: DataQuality::DirectoryClient.new)
      return Set.new if candidate_ids.empty?

      confirm_identical(candidate_ids, by:, dry_run: true, directory:).select(&:ok?).to_set(&:candidate_id)
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      # A merge under way holds the rows: the list shows without the Close label this time.
      Set.new
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

    # Undo for Today's Reject (#373): only a Reject, which changes nothing but
    # the claims (notes are kept, so nothing is lost), and only while they're
    # still as that Reject left them. A Reject that also retired the record
    # its claims proposed has no Undo, and neither has an Accept: it may have
    # published or changed a record, so it's taken back on the record (Edit,
    # Take off), never by a blind reversal.
    #   before = Review.undo_state(id)              # before the decision
    #   state = Review.undoable(before, by:)        # after it; nil: no Undo
    #   Review.undo_all([ state ], by:)             # all or none
    def undo_state(candidate_id)
      candidate = Candidate.find_by(id: candidate_id) or return
      { "id" => candidate.id, "status" => candidate.status }
    end

    def undoable(state, by:, directory: DataQuality::DirectoryClient.new)
      candidate = (Candidate.find_by(id: state["id"]) if state) or return
      return unless candidate.status_rejected? && candidate.reviewed_by == by
      # The Reject retired the record it proposed (or another claim's): that stays.
      return if candidate.subject_id && directory.fact(type: candidate.subject_type, id: candidate.subject_id)&.closed?

      state.merge("stamp" => undo_stamp(candidate))
    end

    # Several at once (the same fact from several pages): every claim is
    # locked and checked first, then all are reopened, or none.
    def undo_all(states, by:, directory: DataQuality::DirectoryClient.new)
      human!(by)
      result = nil
      Candidate.transaction do
        candidates = Candidate.where(id: states.map { |state| state["id"] }).order(:id).lock.index_by(&:id)
        # Their records, locked after the claims as a decision locks them, and
        # still open: one closed since (another claim's Reject retired it) can't take a claim back.
        candidates.values.select(&:subject_id).map { |c| [ c.subject_type, c.subject_id ] }.uniq.sort.each { |type, id| directory.lock_fact(type:, id:) }
        closed = candidates.values.find { |c| c.subject_id && directory.fact(type: c.subject_type, id: c.subject_id)&.closed? }
        if closed
          result = Result.new(candidate_id: closed.id, ref: nil, errors: [ "the record it was about was decided since, so it can't be undone here" ])
          next
        end
        changed = states.reject { |state| (candidate = candidates[state["id"]]) && undo_stamp(candidate) == state["stamp"] }
        if changed.any?
          result = Result.new(candidate_id: changed.first["id"], ref: nil, errors: [ "it changed since, so it can't be undone here" ])
          next
        end

        states.each { |state| candidates.fetch(state["id"]).update!(status: state["status"], reviewed_by: nil, reviewed_at: nil) }
        result = Result.new(candidate_id: states.first["id"], ref: nil, errors: [])
      end
      result
    # Undo locks claims before records, as a decision does; a merge locks
    # records first. If the two meet, Postgres aborts one: the whole Undo
    # rolled back, so it says to try again instead of an error page.
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      Result.new(candidate_id: states.first&.dig("id"), ref: nil, errors: [ BUSY ])
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

    # Adds a company (with its first role) or a plant site by hand (#202),
    # as `by`'s, from a public source and its quote. It starts unpublished
    # (pending): publishing it is a separate decision. dry_run: everything is
    # checked and written, then rolled back, for the preview. Returns Added.
    def add_record(kind:, name:, url:, quote:, by:, website: nil, role: nil, facility_type: nil, dry_run: false,
      directory: DataQuality::DirectoryClient.new)
      human!(by)
      name, url, quote = name.to_s.squish, url.to_s.strip, quote.to_s.squish
      errors = [ ("Give it a name" if name.empty?),
        ("Choose what it does" if kind == "organization" && role.blank?),
        ("Enter a link to a public source, starting with https://" unless url.match?(%r{\Ahttps?://\S+\z})),
        ("Copy the sentence from the source that names it" if quote.empty?) ].compact
      errors << "Choose a company or a plant" unless %w[organization facility].include?(kind)
      return Added.new(ref: nil, errors:, existing: nil) if errors.any?

      existing = kind == "organization" ? directory.organization(name:) : directory.facility(name:)
      return Added.new(ref: nil, errors: [ "#{name} is already in the directory" ], existing:) if existing

      # A company is also the same one by its website's domain: writing it
      # would update that company (rename it, set it pending) instead.
      domain = (directory.domain_from(website.to_s.strip) if kind == "organization" && website.present?)
      if domain && (same_site = directory.organization(domain:))
        return Added.new(ref: nil, errors: [ "#{same_site.name} already has the website #{domain}" ], existing: same_site)
      end

      added = nil
      ApplicationRecord.transaction do
        source = DataQuality::Sources.find_or_create(url:)
        unless source.ok?
          added = Added.new(ref: nil, errors: [ "Enter a link to a public source, starting with https://" ], existing: nil)
          raise ActiveRecord::Rollback
        end

        attributes = kind == "organization" ? { name:, website: website.to_s.strip.presence } : { name:, facility_type: facility_type.presence }
        written = directory.add_fact(kind.to_sym, attributes.compact, source_id: source.ref.id, quote:, by:, reason: ADDED_REASON)
        # Only ever a new record: one the write found by another key is left as it was.
        if written.success? && !written.created
          added = Added.new(ref: nil, errors: [ "It matches a record already in the directory" ],
            existing: (directory.fact(type: written.ref.type, id: written.ref.id) if written.ref))
          raise ActiveRecord::Rollback
        end
        if written.success? && kind == "organization"
          role_written = directory.add_fact(:organization_role, { organization_id: written.ref.id, role: }, source_id: source.ref.id, quote:, by:,
            reason: ADDED_REASON)
          written = role_written.success? ? written : role_written
        end
        added = Added.new(ref: (written.ref if written.success?), errors: written.errors, existing: nil)
        raise ActiveRecord::Rollback if dry_run || !added.ok?
      end
      added
    end

    # Adds a role or a technology to a company by hand (#202), as `by`'s,
    # from a public source and its quote: written pending (publishing it is
    # the usual approval), only ever as a new fact. kind: "role" or
    # "technology"; key: the role's or technology's key. dry_run: checked and
    # written, then rolled back, for the preview. Returns Added.

    def add_company_fact(organization_id:, kind:, key:, url:, quote:, by:, dry_run: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      fact_kind = COMPANY_FACTS[kind]
      url, quote = url.to_s.strip, quote.to_s.squish
      errors = [ ("Choose a role or a technology" unless fact_kind),
        ("Choose which #{kind}" if fact_kind && !directory.company_fact_key?(kind, key)),
        ("Enter a link to a public source, starting with https://" unless url.match?(%r{\Ahttps?://\S+\z})),
        ("Copy the sentence from the source that states it" if quote.empty?) ].compact
      return Added.new(ref: nil, errors:, existing: nil) if errors.any?

      column = fact_kind == :organization_role ? :role : :technology
      if (status = directory.company_fact_status(organization_id:, kind:, key:))
        word = %w[rejected unpublished].include?(status) ? "was taken off this company before, so it can't be added again here" : "is already listed"
        return Added.new(ref: nil, errors: [ "That #{kind} #{word}" ], existing: nil)
      end

      added = nil
      ApplicationRecord.transaction do
        # The source first, key-share locked, then the company, as write_added
        # and approvals take them, so the two can't deadlock.
        source = DataQuality::Sources.find_or_create(url:)
        unless source.ok?
          added = Added.new(ref: nil, errors: [ "Enter a link to a public source, starting with https://" ], existing: nil)
          raise ActiveRecord::Rollback
        end
        ::Source.lock("FOR KEY SHARE").find(source.ref.id)

        # The company locked and checked with the write: one taken off or
        # merged away since the form was shown takes no new fact.
        directory.lock_fact(type: "Organization", id: organization_id)
        unless ActiveRecord::Base.uncached { %w[verified pending].include?(directory.fact(type: "Organization", id: organization_id)&.verification_status) }
          added = Added.new(ref: nil, errors: [ "This company was taken off or merged since, so nothing was added" ], existing: nil)
          raise ActiveRecord::Rollback
        end

        written = directory.add_fact(fact_kind, { organization_id:, column => key.to_s }, source_id: source.ref.id, quote:, by:, reason: ADDED_REASON)
        errors = written.success? ? (written.created ? [] : [ "That #{kind} is already listed" ]) : written.errors
        added = Added.new(ref: (written.ref if errors.empty?), errors:, existing: nil)
        raise ActiveRecord::Rollback if dry_run || !added.ok?
      end
      added
    end

    # Adds a link by hand (#202 part 2b), pending, from a source and its
    # quote. kind: "company_link" (record and other are companies; swap
    # reverses which comes first) or "plant_link" (record is a plant site,
    # other the company). share: owns only, 0 to 100. Dates optional.
    # Returns [Added, LinkPlan or nil].
    def add_link(kind:, record_id:, other_id:, verb:, url:, quote:, by:, share: nil, started_on: nil, ended_on: nil, swap: false,
                 dry_run: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      company_link = kind == "company_link"
      verbs = company_link ? COMPANY_LINK_VERBS : PLANT_LINK_VERBS
      record = directory.fact(type: company_link ? "Organization" : "Facility", id: record_id)
      other = (directory.fact(type: "Organization", id: other_id) if other_id.present?)
      share = share.to_s.strip.presence
      starts, ends = [ started_on, ended_on ].map { |date| date.presence && (Date.iso8601(date.to_s) rescue :bad) }
      # Same id means the same record only between two companies (a plant and a company are different tables).
      errors = [ ("That record is no longer in the directory" unless record),
        ("Choose the company it's linked to" unless other && open_record?(other) && !(company_link && other.id == record&.id)),
        ("Choose how they're linked" unless verbs.key?(verb.to_s)),
        # Two decimal places at most, as the share is stored: what's confirmed is what's saved.
        ("A share is a number from 0 to 100, with at most two decimal places" if share && !(share.match?(/\A\d+(\.\d{1,2})?\z/) && share.to_d.between?(0, 100))),
        ("Only an owner has a share" if share && verb.to_s != "owns"),
        ("Enter dates as they're shown" if [ starts, ends ].include?(:bad)),
        ("It can't end before it starts" if starts.is_a?(Date) && ends.is_a?(Date) && ends < starts),
        *source_errors(url, quote) ].compact
      return [ Added.new(ref: nil, errors:, existing: nil), nil ] if errors.any?

      ends_of = ->(fact, type) { [ type, fact.id, fact.name ] }
      from, to = company_link ? [ ends_of.(record, "Organization"), ends_of.(other, "Organization") ] : [ ends_of.(other, "Organization"), ends_of.(record, "Facility") ]
      from, to = to, from if company_link && swap
      plan = LinkPlan.new(from:, to:, verb: verbs.fetch(verb.to_s), share: (share&.to_f), started_on: starts, ended_on: ends)
      fact_kind, attributes = if company_link
        [ :relationship, { from_organization_id: from[1], to_organization_id: to[1] } ]
      else
        [ :facility_relationship, { organization_id: from[1], facility_id: to[1], ownership_pct: share&.to_d } ]
      end
      attributes = attributes.merge(relationship_type: verb.to_s, started_on: starts, ended_on: ends).compact
      [ write_added(fact_kind, attributes, url:, quote:, by:, dry_run:, duplicate: "That link already exists", directory:,
        parents: [ from.first(2), to.first(2) ]), plan ]
    end

    # Adds a unit under a plant site by hand (#202 part 2b), pending: a name
    # and an optional NRC docket. Type, capacity and status are set after,
    # through Edit and Change status. Returns Added.
    def add_unit(site_id:, name:, url:, quote:, by:, docket: nil, dry_run: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      name, docket = name.to_s.squish, docket.to_s.strip.presence
      site = directory.fact(type: "Facility", id: site_id)
      errors = [ ("That plant is no longer in the directory" unless site), ("Enter the unit's name" if name.empty?),
        ("An NRC docket is 8 digits, like 05000424" if docket && !docket.match?(/\A\d{8}\z/)), *source_errors(url, quote) ].compact
      return Added.new(ref: nil, errors:, existing: nil) if errors.any?

      write_added(:facility, { name:, parent_id: site.id, nrc_docket: docket }.compact, url:, quote:, by:, dry_run:,
        duplicate: "That unit is already listed", directory:, parents: [ [ "Facility", site.id ] ])
    end

    # What publishing this record would put on the site (#202): its approved
    # facts go public with it; the facts added by hand with it (Add a record,
    # Add a fact) are still waiting, and publish with it only if asked.
    def publish_plan(type:, id:, directory: DataQuality::DirectoryClient.new)
      goes_live_with, added_with = directory.publish_counts(type:, id:, added_reason: ADDED_REASON)
      PublishPlan.new(goes_live_with:, added_with:)
    end

    # Publishes a record not yet public (#202): it's approved as `by`'s
    # decision (it needs a source), and with_added: the facts added by hand
    # with it too. All or nothing. Returns a Result.
    def publish(type:, id:, by:, with_added: false, directory: DataQuality::DirectoryClient.new)
      human!(by)
      result = nil
      ApplicationRecord.transaction do
        # Locked and checked with the write: a record rejected, taken off or
        # merged since the page was shown isn't published again.
        directory.lock_fact(type:, id:)
        unless (now = directory.fact(type:, id:)&.verification_status) == "pending"
          result = Result.new(candidate_id: nil, ref: nil, errors: [ "it's #{now || 'gone'} now, so it wasn't published" ])
          raise ActiveRecord::Rollback
        end
        result = approve_fact(type:, id:, by:, reason: "Published", directory:)
        raise ActiveRecord::Rollback unless result.ok?

        # with_added: the facts the preview listed ("Type:id"), or a falsy
        # value for none. Only exactly those: a fact added since isn't taken.
        added_with = with_added ? publish_plan(type:, id:, directory:).added_with : []
        if with_added.is_a?(Array) && with_added.map(&:to_s).sort != added_with.map { |fact_type, fact_id, _| "#{fact_type}:#{fact_id}" }.sort
          result = Result.new(candidate_id: nil, ref: nil, errors: [ "what was added with it changed since the preview; check it again" ])
          raise ActiveRecord::Rollback
        end
        added_with.each do |fact_type, fact_id, name|
          # Each locked and still waiting, as the record is.
          directory.lock_fact(type: fact_type, id: fact_id)
          added = if directory.fact(type: fact_type, id: fact_id)&.verification_status == "pending"
            approve_fact(type: fact_type, id: fact_id, by:, reason: "Published with its record", directory:)
          else
            Result.new(candidate_id: nil, ref: nil, errors: [ "it was decided since the preview" ])
          end
          next if added.ok?

          result = Result.new(candidate_id: nil, ref: nil, errors: added.errors.map { |error| "#{name}: #{error}" })
          raise ActiveRecord::Rollback
        end
      end
      result
    end

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
        safe_check: nil, source_held: false)
        Candidate.transaction do
          lock_for_decision(candidate)
          next Result.new(candidate_id: candidate.id, ref: nil, errors: [ already(candidate) ]) unless open?(candidate)
          next Result.new(candidate_id: candidate.id, ref: nil, errors: [ LEAD ]) if lead?(candidate)
          if only_recommended && !(source_held && data_quality_reviewed) &&
              !(candidate.ai_recommendation == "recommend_publish" && !candidate.status_needs_review?)
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
            key, type = DataQuality::Stages::Match::LINK_ENDS.fetch(candidate.kind, {}).find { |end_key, _| candidate.notes.to_s.start_with?(end_key) }
            name = (candidate.payload.dig(key, "name") if key)
            which = name ? "#{type == :facility ? 'plant' : 'company'} “#{name}” is" : "company or plant it names"
            next Result.new(candidate_id: candidate.id, ref: nil,
              errors: [ "nothing was approved: which #{which} isn't settled yet. Settle that first (Same as…, or Data Quality), then approve it" ])
          end
          if lapsed?(candidate)
            next Result.new(candidate_id: candidate.id, ref: nil,
              errors: [ "its source changed after the verifier checked it; the next verify run checks it again" ])
          end
          if (other = other_page(candidate, directory))
            next Result.new(candidate_id: candidate.id, ref: nil,
              errors: [ "its link already cites #{other.title.presence || other.url}, another page of this source; approving this would replace what that page says (#390)" ])
          end

          # The evidence belongs to the run that judged it (verify), else the one that found it.
          run = candidate.verify_run || candidate.crawl_run
          confidence = edited ? nil : supporting_confidence(candidate)
          result = directory.write_fact(candidate, confidence:, crawl_run: run, by:, reason:, edited:)
          next Result.new(candidate_id: candidate.id, ref: nil, errors: result.errors) unless result.success?

          # A news item stays attached to the company or plant it's about (#137): its page is where it shows.
          attached = candidate.kind == "news_item" ? {} : { subject_type: result.ref.type, subject_id: result.ref.id }
          candidate.update!(status: "merged", **attached, reviewed_by: by, reviewed_at: Time.current)
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
        # A page cited by hand (Research) with nothing stored can't be read:
        # the exact-quote evidence check stands in, as before it had a plug-in.
        return if candidate.source.source_kind == "web_page" && candidate.source.content_text.blank?

        plugin = DataQuality::Plugin.for(candidate.source.source_kind)
        ->(quote) { plugin.quote_in_source?(candidate.source, quote) }
      rescue DataQuality::Plugin::UnknownSourceKind
        nil
      end
      # Also used by DataQuality::Matching (#548).
      public :in_source

      # Match's guard again, at the decision (#392): another page of the same
      # source kind that the claim's link cites now, which the claim would
      # replace. Two claims can attach before either page's evidence is there.
      def other_page(candidate, directory)
        return unless %w[relationship facility_relationship].include?(candidate.kind) && candidate.subject_id

        directory.lock_fact(type: candidate.subject_type, id: candidate.subject_id)
        existing = directory.fact(type: candidate.subject_type, id: candidate.subject_id) or return
        DataQuality::Stages::Match.other_page_on(candidate, existing, directory:)
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

      # What Undo checks is unchanged: the claim as that Reject left it.
      # A merge repoints claims with update_all (no updated_at), so the record and proposal flag are in it too.
      def undo_stamp(candidate) = [ candidate.status, candidate.reviewed_by, candidate.reviewed_at&.to_f, candidate.updated_at.to_f,
        candidate.subject_type, candidate.subject_id, candidate.proposed_subject ].join("|")

      def open_record?(fact) = %w[verified pending].include?(fact.verification_status)

      def source_errors(url, quote)
        [ ("Enter a link to a public source, starting with https://" unless url.to_s.strip.match?(%r{\Ahttps://\S+\z})),
          ("Copy the sentence from the source that states it" if quote.to_s.squish.empty?) ]
      end

      # Writes a fact added by hand, pending, with its source; an existing
      # one isn't touched: it's refused with `duplicate`, and its ref.
      # parents: [[type, id], …] the fact hangs on, locked and checked still
      # live or waiting with the write (one taken off meanwhile takes nothing).
      def write_added(fact_kind, attributes, url:, quote:, by:, dry_run:, duplicate:, directory:, parents: [])
        added = nil
        ApplicationRecord.transaction do
          # The source first, key-share locked (as its evidence's foreign key
          # will), as a decision locks its source before its records; then the
          # records in one order (table, then id), as FactWriter's link ends
          # are. So this can't deadlock with an approval or another addition.
          source = DataQuality::Sources.find_or_create(url: url.to_s.strip)
          unless source.ok?
            added = Added.new(ref: nil, errors: [ "Enter a link to a public source, starting with https://" ], existing: nil)
            raise ActiveRecord::Rollback
          end
          ::Source.lock("FOR KEY SHARE").find(source.ref.id)

          parents = parents.uniq.sort_by { |type, id| [ type, id ] }
          parents.each { |type, id| directory.lock_fact(type:, id:) }
          # Read fresh under the locks: a cached read from before them could
          # miss a Take off or Merge committed in between.
          if ActiveRecord::Base.uncached { parents.any? { |type, id| !(fact = directory.fact(type:, id:)) || !open_record?(fact) } }
            added = Added.new(ref: nil, errors: [ "A record it's on was taken off or merged since, so nothing was added" ], existing: nil)
            raise ActiveRecord::Rollback
          end

          written = directory.add_fact(fact_kind, attributes, source_id: source.ref.id, quote: quote.to_s.squish, by:, reason: ADDED_REASON)
          added = if !written.success? then Added.new(ref: nil, errors: written.errors, existing: nil)
          elsif written.created then Added.new(ref: written.ref, errors: [], existing: nil)
          else Added.new(ref: nil, errors: [ duplicate ], existing: written.ref)
          end
          # Nothing's kept unless it's new and this isn't a preview (an existing
          # one may have had this source added as evidence: undone too).
          raise ActiveRecord::Rollback if dry_run || !added.ok?
        end
        added
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
      def locked_keys(kind) = DataQuality::Review.read_only_keys(kind)

      def item(candidate, directory)
        record = directory.attached_record(candidate)
        differences = DataQuality::Differences.with_human_verified(candidate, record, directory:)
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
