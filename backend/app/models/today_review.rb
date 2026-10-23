# Step 3 of the admin's Today (#373): the facts waiting for a decision,
# each with Joy's verdict (the app's checker) and Aminah's (Data Quality's
# list), sorted into three runs: they agree, only Joy checked it, they
# disagree. Joy says "accept" (recommended) or "check" (anything else);
# Aminah says accept, reject, or nothing (not reviewed, or the fact changed
# since she did). They agree only when both say accept.
#
# Every waiting fact is sorted (a light read), newest first; each run shows
# its first `shown` pages and says how many more there are.
#
#   review = TodayReview.new(shown: { "agree" => 2 })
#   review.rows("agree")  # => [Row, …], the newest 2 × PAGE
#   review.count("agree") # => all of them
class TodayReview
  GROUPS = %w[agree only_joy disagree].freeze
  PAGE = 50
  # others: the same fact from other pages (or the same new company
  # several pages propose), decided with it in one click.
  Row = Data.define(:item, :joy, :aminah, :group, :others) do
    def initialize(others: [], **) = super
    def candidate_id = item.candidate_id
    def candidate_ids = [ item, *others ].map(&:candidate_id)
    def agree? = group == "agree"
  end

  def initialize(shown: {}, directory: DataQuality::DirectoryClient.new)
    @shown = GROUPS.to_h { |group| [ group, shown[group].to_i.clamp(1, 1000) ] }
    @directory = directory
    # "No list from Aminah today" (step 2): her earlier calls don't count today.
    @no_list = TodayStep.exists?(on: Today.date, step: "list", note: "no_list")
  end

  # Aminah's reason for a row, unless today has no list from her.
  def aminah_reason(item) = (item.dq_reason unless @no_list)

  # { group => [[candidate id, …] per fact], … }: each fact's copies
  # together (so a page never splits a fact), newest fact first.
  def clusters
    @clusters ||= begin
      # A trade-press lead (#127) waits for Data Quality's primary source, never here.
      waiting = Candidate.where(id: DataQuality::Review.check_ids(category: "all"))
        .where("candidates.payload->>'lead' IS DISTINCT FROM 'true'").order(id: :desc).to_a
      by_group = waiting.group_by { |candidate| group_of(*verdicts(candidate)) }
      GROUPS.to_h { |group| [ group, Array(by_group[group]).group_by { |candidate| same_fact(candidate) }.values.map { |copies| copies.map(&:id) } ] }
    end
  end

  # { group => [candidate id, …] }, newest first.
  def ids = @ids ||= clusters.transform_values(&:flatten)

  def rows(group)
    @rows ||= {}
    @rows[group] ||= begin
      shown_ids = clusters.fetch(group).first(shown(group))
      items = DataQuality::Review.items(shown_ids.flatten, directory: @directory).index_by(&:candidate_id)
      shown_ids.filter_map do |copies|
        item, *others = copies.filter_map { |id| items[id] }
        next unless item

        joy, aminah = verdicts(item)
        Row.new(item:, joy:, aminah:, group:, others:)
      end
    end
  end

  # Pages count facts (each with all its copies); the heading counts claims.
  def shown(group) = @shown.fetch(group) * PAGE
  def pages(group) = @shown.fetch(group)
  def count(group) = ids.fetch(group).size
  def more(group) = [ clusters.fetch(group).size - shown(group), 0 ].max
  def size = ids.values.sum(&:size)

  # Aminah's recommendations on the agreed rows shown, as her list's Accept
  # takes them (checked again under the decision's locks).
  # Each agreed fact's other copies (from other pages), approved after its
  # first is accepted: { first id => [other ids] }.
  def agreed_copies = rows("agree").to_h { |row| [ row.candidate_id, row.candidate_ids - [ row.candidate_id ] ] }

  def agreed_items
    rows("agree").flat_map(&:candidate_ids).map do |id|
      candidate = Candidate.find(id)
      DataQuality::Recommendations::Item.new(candidate_id: candidate.id, call: candidate.dq_recommendation, reason: candidate.dq_reason,
        snapshot: candidate.dq_payload_sha256, claim: nil, subject_type: candidate.subject_type, subject_id: candidate.subject_id, why: nil, waiting: true)
    end
  end

  def fingerprint = DataQuality::Recommendations.fingerprint(agreed_items)

  private
    # One fact, whichever page states it: the same kind of claim on the same
    # record with the same values, or, for a new company several pages
    # propose, the same kind and name.
    # Copies only group when their verdicts match too, so the chips shown are
    # true of every copy; values are exact (only a proposed new record's
    # name is compared loosely).
    def same_fact(record)
      id = record.respond_to?(:candidate_id) ? record.candidate_id : record.id
      key = if record.subject_id then [ record.kind, record.subject_type, record.subject_id, record.payload.to_h.except("quote").sort ]
      elsif record.kind == "organization"
        # The same name loosely; every other value exactly, since Accept writes each copy's.
        name = record.payload.to_h["name"].to_s.squish.downcase.presence
        name ? [ record.kind, name, record.payload.to_h.except("name", "quote").sort ] : [ :own, id ]
      else [ :own, id ] # an unattached plant or link is decided on its own (its docket or ends may differ)
      end
      [ *key, *verdicts(record) ]
    end

    # [joy, aminah] for a candidate or a Checks item. Aminah's call counts
    # only while it stands (the fact hasn't changed since she made it).
    def verdicts(record)
      # A claim sent back to review keeps its old verdict field; review wins.
      joy = record.ai_recommendation == "recommend_publish" && record.status.to_s != "needs_review" ? "accept" : "check"
      return [ joy, nil ] if @no_list
      call = record.is_a?(Candidate) ? (record.dq_recommendation if DataQuality::Recommendations.current?(record)) : record.dq_recommendation
      [ joy, { "approve" => "accept", "reject" => "reject" }[call] ]
    end

    def group_of(joy, aminah)
      if aminah.nil? then "only_joy"
      elsif joy == "accept" && aminah == "accept" then "agree"
      else "disagree"
      end
    end
end
