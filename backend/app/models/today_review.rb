# Step 3 of the admin's Today (#373): the facts waiting for a decision,
# each with Joy's verdict (the app's checker) and Aminah's (Data Quality's
# list), sorted into three runs: they agree, only Joy checked it, they
# disagree. Joy says "accept" (recommended) or "check it" (anything else);
# Aminah says accept, reject, or nothing (not reviewed). They agree only
# when both say accept: Joy never says reject, so a "check it" against
# Aminah's reject is still the admin's own call.
#
#   review = TodayReview.new
#   review.rows("agree") # => [Row, …]
class TodayReview
  GROUPS = %w[agree only_joy disagree].freeze
  Row = Data.define(:item, :joy, :aminah, :group) do
    def candidate_id = item.candidate_id
    def agree? = group == "agree"
  end

  def initialize(limit: 200, directory: DataQuality::DirectoryClient.new)
    @limit, @directory = limit, directory
  end

  def all
    @all ||= DataQuality::Review.checks(category: "all", limit: @limit, directory: @directory).map do |item|
      joy = item.ai_recommendation == "recommend_publish" ? "accept" : "check"
      aminah = { "approve" => "accept", "reject" => "reject" }[item.dq_recommendation]
      group = if aminah.nil? then "only_joy"
      elsif joy == "accept" && aminah == "accept" then "agree"
      else "disagree"
      end
      Row.new(item:, joy:, aminah:, group:)
    end.reverse # newest first within each run
  end

  def rows(group) = all.select { |row| row.group == group }
  def count(group) = rows(group).size
  def size = all.size
end
