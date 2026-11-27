require "test_helper"
require_relative "../test_helpers/fake_checker_llm"

# #776: the nightly checker in shadow: code holds first, the cheap model, the verify model on unsure,
# the hard rules after an approve, and its limits counted from the database.
class DqCheckerTest < ActiveSupport::TestCase
  BY = "human:tosin".freeze
  NOW = Time.utc(2026, 11, 21, 9, 30)

  setup do
    @page = Source.create!(url: "https://acmefission.com/", source_kind: "dummy", crawl_status: "ok", content_sha256: "s",
      content_text: "Welcome. Acme Fission builds small fission reactors in Ohio. Contact us.")
    @company = Organization.create!(name: "Acme Fission", verification_status: "pending")
  end

  def website_claim(company: @company, website: "https://acmefission.com", quote: "Acme Fission builds small fission reactors in Ohio", **)
    Candidate.create!(source: @page, kind: "organization", payload: { "name" => company.name, "website" => website }, quote:,
      subject: company, status: "needs_review", **)
  end

  def checker(llm) = DqChecker.new(llm:, now: NOW)

  test "the cheap model's unsure goes to the verify model; the verdict is kept, nothing else changes" do
    claim = website_claim
    llm = FakeCheckerLlm.new(extract: [ [ "unsure", "thin" ] ], verify: [ [ "approve", "Its own home page names it and its reactors" ] ])
    assert_equal({ "approve" => 1 }, checker(llm).run)

    verdict = CheckerVerdict.sole
    assert_equal [ claim.id, "website", "approve", "fake-verify", true ], verdict.values_at(:candidate_id, :field, :verdict, :model, :escalated)
    assert_equal %i[extract verify], llm.asked.map(&:first)
    assert_includes llm.asked.first.last, "Acme Fission builds small fission reactors", "it reads the page around the quote"
    assert_nil claim.reload.dq_recommendation, "shadow: no recommendation recorded"
    assert_equal "needs_review", claim.status

    assert_equal({}, checker(llm).run.except("skipped"), "a claim is judged once per prompt version")
  end

  test "code holds before any model: contradicted, a value we hold, a rejected company, a quote not on the page" do
    contradicted = website_claim(ai_reason: "#{DataQuality::Verifiers::Agent::CONTRADICTS} (the source gives x): y")
    held = Organization.create!(name: "Held Co", website: "https://held.example", verification_status: "pending")
    changes = website_claim(company: held, website: "https://heldco.com")
    gone = website_claim(company: Organization.create!(name: "Gone Co", verification_status: "rejected", verified_by: BY))
    misquoted = website_claim(quote: "Acme Fission makes fusion magnets")
    Candidate.create!(source: @page, kind: "relationship", payload: {}, quote: "q", status: "needs_review")
    llm = FakeCheckerLlm.new

    assert_equal({ "unsure" => 4 }, checker(llm).run)
    assert_empty llm.asked
    reasons = CheckerVerdict.order(:candidate_id).pluck(:candidate_id, :reason).to_h
    assert_match "contradicts", reasons[contradicted.id]
    assert_equal "Changes a value we hold (website)", reasons[changes.id]
    assert_match "rejected", reasons[gone.id]
    assert_equal "The quote isn't on the stored page", reasons[misquoted.id]
  end

  test "the hard rules only lower an approve: a shared name, another company's site, not a home page" do
    shared = website_claim(company: Organization.create!(name: "Atlas", verification_status: "pending"),
      quote: "Acme Fission builds small fission reactors in Ohio")
    Organization.create!(name: "Other Co", website: "https://www.othersite.com/", verification_status: "verified", verified_by: BY)
    taken = website_claim(website: "https://othersite.com")
    deep = website_claim(website: "https://acmefission.com/about")
    rejected = website_claim
    llm = FakeCheckerLlm.new(extract: [ [ "approve", "ok" ], [ "approve", "ok" ], [ "approve", "ok" ], [ "reject", "names another company" ] ])

    checker(llm).run
    reasons = CheckerVerdict.pluck(:candidate_id, :verdict, :reason).to_h { |id, *rest| [ id, rest ] }
    assert_equal [ "unsure", "The name is shared by many companies" ], reasons[shared.id]
    assert_equal [ "unsure", "Another company already has this site" ], reasons[taken.id]
    assert_equal [ "unsure", "Not an https home page" ], reasons[deep.id]
    assert_equal [ "reject", "names another company" ], reasons[rejected.id], "a reject stays a reject"
  end

  test "an error or the spent budget is unsure, never an approve; the day's limits come from the database" do
    website_claim
    checker(FakeCheckerLlm.new(error: DataQuality::OpenRouter::Client::Error.new("down"))).run
    assert_equal [ "unsure", "Needs a human: the model didn't answer (Error)" ], CheckerVerdict.sole.values_at(:verdict, :reason)

    CheckerVerdict.delete_all
    CrawlRun.create!(source_kind: "dq_checker", stage: "verify", started_at: NOW - 1.hour, stats: { "llm" => { "cost" => 1.0 } })
    assert_equal 1, checker(FakeCheckerLlm.new).run["stopped_for_budget"]
    assert_equal 0, CheckerVerdict.count

    CrawlRun.where(source_kind: "dq_checker").delete_all
    DqChecker::LIMIT.times { |i| CheckerVerdict.create!(candidate: website_claim, field: "website", verdict: "unsure", reason: "r", prompt_version: "old#{i}", created_at: NOW) }
    assert_match "done", checker(FakeCheckerLlm.new).run["skipped"]
  end

  test "the checker shares Data Quality's pass's daily cap: the pass's spend stops it too (#998)" do
    website_claim
    CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify", started_at: NOW - 1.hour, stats: { "llm" => { "cost" => DqPass::DAILY_BUDGET } })
    assert_equal 1, checker(FakeCheckerLlm.new).run["stopped_for_budget"]
    assert_equal 0, CheckerVerdict.count
  end

  test "fields by what a claim fills; anything else is never judged" do
    field = ->(kind, payload) { DqChecker.field_for(kind, payload) }
    assert_equal "new_company", field.("organization", { "name" => "A", "aliases" => [] })
    assert_equal "hq", field.("organization", { "name" => "A", "hq_city" => "Reno", "hq_state" => "NV" })
    assert_equal "other", field.("organization", { "name" => "A", "hq_city" => "Reno", "website" => "https://a.com" })
    assert_equal "role", field.("organization_role", {})
    assert_equal "relationship", field.("relationship", {})
  end

  test "the page window is read in SQL around the quote, markup dropped; the start when the quote isn't found (Infra)" do
    @page.update!(content_text: "<p>#{'filler ' * 20_000}</p><p>Acme Fission builds small fission reactors in Ohio.</p>#{'tail ' * 5_000}")
    window = checker(FakeCheckerLlm.new).window(website_claim)
    assert_includes window, "Acme Fission builds small fission reactors in Ohio"
    assert_operator window.length, :<=, DqChecker::WINDOW
    assert_not_includes window, "<p>"
    assert checker(FakeCheckerLlm.new).window(website_claim(quote: "nowhere on it")).start_with?("filler")
  end

  test "news is approved only about companies we hold; a new company or role from an award or NRC row alone is unsure (DQ)" do
    held = Candidate.create!(source: @page, kind: "news_item", quote: "Acme Fission builds small fission reactors in Ohio", status: "new",
      payload: { "title" => "Acme Fission news", "about" => [ { "name" => "Acme Fission", "type" => "organization" } ] })
    not_held = Candidate.create!(source: @page, kind: "news_item", quote: "Acme Fission builds small fission reactors in Ohio", status: "new",
      payload: { "title" => "Other news", "about" => [ { "name" => "Deep Elsewhere", "type" => "organization" } ] })
    row = Source.create!(url: "https://www.usaspending.gov/recipient/x", source_kind: "usaspending_doe_awards", crawl_status: "ok", content_sha256: "u",
      content_text: "DE123,ACME FUSION INC,100000")
    award = Candidate.create!(source: row, kind: "organization", payload: { "name" => "Acme Fusion" }, quote: "DE123,ACME FUSION INC,100000", status: "new")
    checker(FakeCheckerLlm.new(extract: Array.new(3) { [ "approve", "ok" ] })).run

    verdicts = CheckerVerdict.pluck(:candidate_id, :verdict, :reason).to_h { |id, *rest| [ id, rest ] }
    assert_equal "approve", verdicts[held.id].first
    assert_equal [ "unsure", "News only for companies we hold; this one isn't in the directory" ], verdicts[not_held.id]
    assert_equal [ "unsure", "Only an award or register row names it; nuclear work needs its own page" ], verdicts[award.id]
  end

  test "Copilot: split claims' field_of is ignored; a role's company and an unmatched claim are found or held; budget checked before each call" do
    assert_equal "hq", DqChecker.field_for("organization", { "name" => "A", "hq_city" => "Reno", "field_of" => 7 })

    gone = Organization.create!(name: "Gone Role Co", verification_status: "rejected", verified_by: BY)
    role = Candidate.create!(source: @page, kind: "organization_role", payload: { "organization" => { "name" => "Gone Role Co" }, "role" => "fuel" },
      quote: "Acme Fission builds small fission reactors in Ohio", status: "new")
    unmatched = Candidate.create!(source: @page, kind: "organization", payload: { "name" => "Nobody Here", "website" => "https://nobody.example" },
      quote: "Acme Fission builds small fission reactors in Ohio", status: "new")
    llm = FakeCheckerLlm.new
    checker(llm).run
    reasons = CheckerVerdict.pluck(:candidate_id, :reason).to_h
    assert_match "rejected", reasons[role.id], "found #{gone.name} by name"
    assert_equal "Not matched to one company yet", reasons[unmatched.id]
    assert_empty llm.asked

    CheckerVerdict.delete_all
    claim = website_claim
    spend = FakeCheckerLlm.new(extract: [ [ "unsure", "thin" ] ])
    spend.define_singleton_method(:structured) do |**args|
      result = super(**args)
      args[:crawl_run].update!(stats: { "llm" => { "cost" => 1.0 } })
      result
    end
    checker(spend).run
    assert_equal [ :extract ], spend.asked.map(&:first), "no verify call once the day's budget is spent"
    assert_match "budget", CheckerVerdict.find_by!(candidate_id: claim.id).reason
  end
end
