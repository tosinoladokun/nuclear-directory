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
  Row = Data.define(:item, :joy, :aminah, :group) do
    def candidate_id = item.candidate_id
    def agree? = group == "agree"
  end

  def initialize(shown: {}, directory: DataQuality::DirectoryClient.new)
    @shown = GROUPS.to_h { |group| [ group, shown[group].to_i.clamp(1, 1000) ] }
    @directory = directory
  end

  # { group => [candidate id, …] }, newest first.
  def ids
    @ids ||= begin
      waiting = DataQuality::Review.check_ids(category: "all")
      grouped = Candidate.where(id: waiting).order(id: :desc).to_a.group_by { |candidate| group_of(*verdicts(candidate)) }
      GROUPS.to_h { |group| [ group, Array(grouped[group]).map(&:id) ] }
    end
  end

  def rows(group)
    @rows ||= {}
    @rows[group] ||= DataQuality::Review.items(ids.fetch(group).first(shown(group)), directory: @directory).map do |item|
      joy, aminah = verdicts(item)
      Row.new(item:, joy:, aminah:, group:)
    end
  end

  def shown(group) = @shown.fetch(group) * PAGE
  def pages(group) = @shown.fetch(group)
  def count(group) = ids.fetch(group).size
  def more(group) = [ count(group) - shown(group), 0 ].max
  def size = ids.values.sum(&:size)

  # Aminah's recommendations on the agreed rows shown, as her list's Accept
  # takes them (checked again under the decision's locks).
  def agreed_items
    rows("agree").map do |row|
      candidate = Candidate.find(row.candidate_id)
      DataQuality::Recommendations::Item.new(candidate_id: candidate.id, call: candidate.dq_recommendation, reason: candidate.dq_reason,
        snapshot: candidate.dq_payload_sha256, claim: nil, subject_type: candidate.subject_type, subject_id: candidate.subject_id, why: nil, waiting: true)
    end
  end

  def fingerprint = DataQuality::Recommendations.fingerprint(agreed_items)

  private
    # [joy, aminah] for a candidate or a Checks item. Aminah's call counts
    # only while it stands (the fact hasn't changed since she made it).
    def verdicts(record)
      joy = record.ai_recommendation == "recommend_publish" ? "accept" : "check"
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
