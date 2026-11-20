require "test_helper"
require_relative "../test_helpers/fake_checker_llm"

# #776: the exam freezes its stratified set once and reports per field, with every disagreement.
class DqCheckerExamTest < ActiveSupport::TestCase
  test "a frozen set made once by kind and verdict; the report counts approvals of DQ rejects and lists disagreements" do
    dir = Dir.mktmpdir
    path = File.join(dir, "exam.jsonl")
    rows = (1..20).map do |id|
      { candidate_id: id, kind: id.even? ? "organization" : "news_item", payload: { "name" => "Co #{id}", "legal_name" => "Co #{id} Inc." },
        quote: "Co #{id} Inc. is a nuclear company", verdict: id % 5 == 0 ? "reject" : "approve", reason: "dq #{id}" }
    end
    File.write(path, rows.map(&:to_json).join("\n"))
    llm = FakeCheckerLlm.new(extract: Array.new(20) { |i| [ i.zero? ? "approve" : "reject", "model #{i}" ] })
    exam = DqChecker::Exam.new(path, checker: DqChecker.new(llm:))

    frozen = exam.frozen_ids
    assert_equal frozen, DqChecker::Exam.new(path).frozen_ids, "frozen once"
    assert frozen.size.between?(1, 20)

    report = exam.run("all")
    assert_match "| all | 20 |", report
    assert_match "## Every disagreement", report
    assert_match "| quote only |", report, "no local claim: only the quote is read"
    assert_equal 20, llm.asked.size
  ensure
    FileUtils.rm_rf(dir)
  end

  test "the frozen places are exactly the total, at least one per stratum (Copilot)" do
    places = DqChecker::Exam.allocate({ a: 349, b: 349, c: 1, d: 1 }, 150)
    assert_equal 150, places.values.sum
    assert_equal [ 1, 1 ], places.values_at(:c, :d)
    assert_equal 5, DqChecker::Exam.allocate({ a: 3, b: 2 }, 10).values.sum, "never more than the rows"
  end
end
