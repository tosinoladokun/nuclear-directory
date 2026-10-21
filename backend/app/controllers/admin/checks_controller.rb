# Checks (#201): what the sources read and found the same, and everything
# waiting for a person: claims from both queues and pending facts, in one
# list with filter chips. Deciding goes through today's actions
# (Admin::CandidatesController, Admin::PendingFactsController), which come
# back here.
class Admin::ChecksController < Admin::BaseController
  PAGE = 50
  CATEGORIES = [ "all", *DataQuality::Review::CATEGORIES ].freeze

  def show
    @category = params[:category].presence_in(CATEGORIES) || "all"
    @source_kind = params[:source].presence
    @counts = DataQuality::Review.check_counts(source_kind: @source_kind)
    # Pending facts have no claim from a source, so a source filter leaves them out.
    pending = @source_kind ? 0 : DataQuality::Review.pending_count
    @counts["facts"] += pending
    @counts["all"] += pending

    @read, @same = DataQuality::Status.read_today.values_at(:read, :same)

    # "Approve N safe": today's Approve all, over the recommended claims this
    # filter shows, so nothing hidden is approved with them.
    ids = DataQuality::Review.safe_ids(category: @category, source_kind: @source_kind)
    @safe = ids.size
    @shown = Admin::CandidatesController.fingerprint(ids)
    # Data Quality's recommendations (#306): how many Accept would decide, and how many are left.
    plan = DataQuality::Recommendations.plan(only_enabled_safe: true)
    @recommended, @recommended_left = plan.accept.size + plan.safe_accept.size, plan.left.size

    load_page(pending.positive? && %w[all facts].include?(@category))
  end

  private
    # Claims first (oldest first, by id), then pending facts kind by kind.
    # after: the last claim id shown ("done" once claims ran out);
    # pending_after: "kind:id" of the last pending fact shown.
    def load_page(with_pending)
      claims_done = params[:after] == "done"
      @items = claims_done ? [] : DataQuality::Review.checks(category: @category, source_kind: @source_kind,
        after_id: params[:after].presence&.to_i, limit: PAGE)
      @facts = []
      if @items.size == PAGE
        @next = { after: @items.last.candidate_id }
      elsif with_pending
        @facts = pending_facts(PAGE - @items.size)
        @next = { after: "done", pending_after: "#{@facts.last.kind}:#{@facts.last.id}" } if @facts.any? && @facts.size == PAGE - @items.size
      end
    end

    def pending_facts(limit)
      kinds = DataQuality::Review.fact_kinds
      kind, after_id = params[:pending_after].to_s.split(":", 2)
      kinds = kinds.drop_while { |k| k != kind } if kinds.include?(kind)
      after_id = after_id.presence&.to_i if kinds.first == kind
      kinds.each_with_object([]) do |each_kind, facts|
        break facts if facts.size >= limit

        facts.concat(DataQuality::Review.pending_facts(kind: each_kind, after_id: (after_id if each_kind == kind), limit: limit - facts.size))
      end
    end

    def filters = { category: (@category unless @category == "all"), source: @source_kind }.compact
    helper_method :filters
end
