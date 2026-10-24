require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# Data Quality's recommendations (#306): paste its list, see exactly what
# Accept decides and what's left for a person, then accept as one decision.
class Admin::RecommendationsTest < ActionDispatch::IntegrationTest
  class Recommend
    def call(candidate) = DataQuality::Verdict.new(outcome: :publish, confidence: 0.92, reason: "The row names #{candidate.payload['name']}.")
  end

  # A source that holds each claim for a person's review, as a new source's
  # first read does (Plugin#hold_for_review).
  class DataQuality::Plugins::HoldDummy < DummyPlugin
    HOLD = "It's a first read of this list: check it"
    def source_kind = "hold_dummy"
    def hold_for_review(_candidate) = HOLD
  end

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/recs.html", source_kind: "dummy", crawl_status: "ok", title: "NRC test page")
    sign_in_as users(:admin)
  end

  # A claim from the source's first batch (held from Approve all) about a
  # company the directory has pending, so match attaches it; the verifier
  # then recommends it.
  def claim(name)
    Directory::FactWriter.write(:organization, { name: }) # pending, with its name as an alias
    run = CrawlRun.where(source_kind: "dummy", stage: "crawl").first_or_create!(status: "succeeded", started_at: 1.hour.ago)
    Candidate.create!(source: @source, kind: "organization", payload: { "name" => name }, quote: "a quote", crawl_run: run)
  end

  def match_and_verify
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "match")
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "verify", verifier: Recommend.new)
  end

  def paste(text) = post admin_recommendations_path, params: { list: text }

  test "a pasted list is recorded and decides nothing; lines it can't read are listed, comments skipped" do
    a, b = claim("Alpha Fission Co"), claim("Beta Fission Co")
    match_and_verify

    paste("# DOE awards, 18 Oct\n\n#{a.id} approve: the page names Alpha\n#{b.id} Reject: a subcontract\nplease approve the rest\n999999 approve: x")

    assert_response :unprocessable_content
    assert_select ".nd-alert p", /Added 2 recommendations\.\s+2 lines weren't added:/
    assert_select ".nd-alert li", /please approve the rest\s*Line 5: it isn't “<id> approve: <reason>”/
    assert_select ".nd-alert li", /999999 approve: x\s*Line 6: there's no fact 999999/
    assert_equal [ "approve", "the page names Alpha" ], a.reload.slice(:dq_recommendation, :dq_reason).values
    assert_equal "reject", b.reload.dq_recommendation
    assert a.status_matched?, "recording decides nothing"
    assert_equal users(:admin).actor, a.dq_by
  end

  test "JSON works too; a list read in full goes back to the plan" do
    a = claim("Alpha Fission Co")
    match_and_verify

    paste([ { id: a.id, recommendation: "approve", reason: "named on the page" } ].to_json)

    assert_redirected_to admin_recommendations_path
    assert_equal "Added 1 recommendation. Nothing is decided until you accept.", flash[:notice]
    follow_redirect!
    assert_select "#rec-#{a.id}", /named on the page/
    assert_equal "approve", a.reload.dq_recommendation
  end

  test "a recommendation commented out is skipped" do
    a = claim("Alpha Fission Co")
    match_and_verify

    paste("#{a.id} approve: ok\n##{a.id} reject: changed my mind\n# #{a.id} reject: also commented")

    assert_redirected_to admin_recommendations_path
    assert_equal "approve", a.reload.dq_recommendation
  end

  test "a claim that changed, then was recommended again the same way, isn't accepted from the old page" do
    a = claim("Alpha Fission Co")
    match_and_verify
    paste("#{a.id} approve: named on the page")
    get admin_recommendations_path
    shown = css_select("form[action='#{admin_recommendations_accept_path}'] input[name=shown]").first["value"]

    a.update!(quote: "a different quote")
    paste("#{a.id} approve: named on the page") # the same call, on the changed claim

    post admin_recommendations_accept_path, params: { shown: }
    assert_match "The list changed since you opened it", flash[:alert]
    assert a.reload.status_matched?
  end

  test "Accept checks the call again under the decision's locks" do
    a = claim("Alpha Fission Co")
    match_and_verify
    paste("#{a.id} approve: named on the page")
    item = DataQuality::Recommendations.plan.accept.sole
    a.update!(dq_recommendation: "reject") # changed between the check and the decision

    result = DataQuality::Recommendations.accept([ item ], by: users(:admin).actor).sole
    assert_equal [ "Data Quality's call on it changed after the page loaded" ], result.errors
    assert a.reload.status_matched?
  end

  test "a left claim that isn't in the queue links to its own page, where it can be decided" do
    a = claim("Alpha Fission Co")
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "match") # attached, never verified
    paste("#{a.id} approve: ok")

    get admin_recommendations_path
    assert_select "#rec-#{a.id} a[href=?]", edit_admin_candidate_path(a.id, back: admin_recommendations_path)
  end

  test "the preview lists exactly what Accept decides, and what's left with why" do
    held = claim("Alpha Fission Co")
    rejected = claim("Beta Fission Co")
    changed = claim("Gamma Fission Co")
    match_and_verify
    unrecommended = claim("Delta Fission Co") # matched, but never verified
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "match")
    paste("#{held.id} approve: named on the page\n#{rejected.id} reject: not nuclear\n#{changed.id} approve: ok\n#{unrecommended.id} approve: ok")
    changed.update!(quote: "a different quote")

    get admin_recommendations_path

    assert_select "#accept-heading", /To accept\s*2/
    assert_select ".nd-recs__accept p", "Each is recorded as yours, with its reason."
    assert_select ".nd-recs__accept button", "Accept: approve 1, reject 1"
    assert_select "#rec-#{changed.id} .nd-recs__label", "Left because:"
    assert_select "#rec-#{held.id}", /Alpha Fission Co.*Approve.*named on the page/m
    assert_select "#rec-#{held.id} td.whitespace-nowrap", "Approve", "the decision stays on one line (DESIGN.md)"
    assert_select "#rec-#{rejected.id}", /Reject.*not nuclear/m
    assert_select "#left-heading", /Left for you\s*2/
    assert_select "#rec-#{changed.id}", /It changed after Data Quality looked at it/
    assert_select "#rec-#{unrecommended.id}", /The app's checker didn't recommend it/
  end

  test "Accept decides the shown list as the person, lifting only the first-batch hold" do
    held = claim("Alpha Fission Co")
    rejected = claim("Beta Fission Co")
    match_and_verify
    assert_equal DataQuality::Review::FIRST_BATCH, DataQuality::Review.held_reason(held.reload), "held from Approve all"
    paste("#{held.id} approve: named on the page\n#{rejected.id} reject: not nuclear")
    get admin_recommendations_path
    shown = css_select("form[action='#{admin_recommendations_accept_path}'] input[name=shown]").first["value"]

    post admin_recommendations_accept_path, params: { shown: }

    assert_redirected_to admin_recommendations_path
    assert_equal "Accepted 2 recommendations.", flash[:notice]
    assert held.reload.status_merged?
    assert_equal users(:admin).actor, held.reviewed_by
    company = Organization.find(held.subject_id)
    assert_equal "Accepted Data Quality's recommendation: named on the page", company.verification_events.order(:id).last.reason
    assert rejected.reload.status_rejected?
    assert_equal "Accepted Data Quality's recommendation: not nuclear", rejected.notes
  end

  test "if the list changed since it was shown, nothing is accepted" do
    a, b = claim("Alpha Fission Co"), claim("Beta Fission Co")
    match_and_verify
    paste("#{a.id} approve: ok")
    get admin_recommendations_path
    shown = css_select("form[action='#{admin_recommendations_accept_path}'] input[name=shown]").first["value"]
    paste("#{b.id} approve: added after the page loaded")

    post admin_recommendations_accept_path, params: { shown: }

    assert_match "The list changed since you opened it", flash[:alert]
    assert a.reload.status_matched?
    assert b.reload.status_matched?
  end

  test "a claim a person decided, or one whose company isn't settled, is never accepted" do
    a = claim("Alpha Fission Co")
    match_and_verify
    Organization.find(a.reload.subject_id).verify!(by: "human:tosin")
    paste("#{a.id} approve: ok")

    get admin_recommendations_path
    assert_select "#rec-#{a.id}", /It would change a record a person decided/

    plan = DataQuality::Recommendations.plan
    assert_empty plan.accept
    assert_equal [ "it would change a record a person decided" ], DataQuality::Recommendations.accept(plan.left, by: users(:admin).actor).first.errors
    assert a.reload.status_matched?
  end

  test "Checks shows each claim's recommendation and how many Accept would decide" do
    a = claim("Alpha Fission Co")
    match_and_verify

    get admin_checks_path
    assert_select "a.nd-btn[href=?]", admin_recommendations_path, "Add Data Quality's list"

    paste("#{a.id} approve: named on the page")
    get admin_checks_path
    assert_select "a.nd-btn[href=?]", admin_recommendations_path, "Data Quality's recommendations (1)"
    assert_select "#claim-#{a.id}", /Data Quality recommends approving:\s*named on the page/
  end

  test "a rejection that fails is undone, so the claim stays open to try again" do
    c = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Imaginary Fission Co" }, quote: "a quote")
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "match") # proposes a new company
    assert c.reload.proposed_subject
    paste("#{c.id} reject: not a real company")
    failing = Class.new(DataQuality::DirectoryClient) do
      def decide_fact(*, **) = DataQuality::DirectoryClient::WriteResult.new(ref: nil, errors: [ "database busy" ])
    end.new

    result = DataQuality::Recommendations.accept(DataQuality::Recommendations.plan.accept, by: users(:admin).actor, directory: failing).sole

    assert_equal [ "database busy" ], result.errors
    assert c.reload.status_matched?, "still open"
    assert DataQuality::Recommendations.accept(DataQuality::Recommendations.plan.accept, by: users(:admin).actor).sole.ok?, "a retry works"
  end

  test "a claim that fills in a record's details is left for its own page" do
    a = claim("Alpha Fission Co")
    match_and_verify
    a.reload.update_columns(payload: a.payload.merge("identify" => { "nrc_docket" => "05000999" }))
    paste("#{a.id} approve: the docket matches")

    get admin_recommendations_path
    assert_select "#rec-#{a.id}", /It fills in a record's details; decide it on its own page/
  end

  test "two approvals of the same record: Accept takes the first and leaves the other, as the preview says" do
    first = claim("Alpha Fission Co")
    match_and_verify
    second = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Alpha Fission Co", "website" => "https://alpha.example" },
      quote: "another quote", crawl_run: first.crawl_run)
    match_and_verify
    assert_equal first.reload.subject_id, second.reload.subject_id
    paste("#{first.id} approve: named on the page\n#{second.id} approve: its website")

    get admin_recommendations_path
    assert_select "#accept-heading", /To accept\s*1/
    assert_select "#rec-#{second.id}", /Another recommendation in this list approves the same record/
  end

  test "a claim removed while Accept waits is skipped, not a crash" do
    a = claim("Alpha Fission Co")
    match_and_verify
    paste("#{a.id} reject: not nuclear")
    item = DataQuality::Recommendations.plan.accept.sole
    a.destroy!

    result = DataQuality::Recommendations.accept([ item ], by: users(:admin).actor).sole
    assert_equal [ "this fact no longer exists" ], result.errors
  end

  test "a reopened claim needs a fresh recommendation" do
    c = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Imaginary Fission Co" }, quote: "a quote")
    paste("#{c.id} reject: not a real company")
    DataQuality::Recommendations.accept(DataQuality::Recommendations.plan.accept, by: users(:admin).actor)
    assert c.reload.status_rejected?

    DataQuality::Review.reopen([ c.id ], by: users(:admin).actor, reason: "Look again")
    get admin_recommendations_path
    assert_select "#rec-#{c.id}", /It changed after Data Quality looked at it/
  end

  test "Checks doesn't show a call that no longer stands: a claim reopened since shows as waiting again" do
    a = claim("Alpha Fission Co")
    match_and_verify
    paste("#{a.id} approve: named on the page")
    get admin_checks_path
    assert_select "#claim-#{a.id}", /Data Quality recommends approving/

    DataQuality::Review.reject([ a.id ], by: users(:admin).actor)
    DataQuality::Review.reopen([ a.id ], by: users(:admin).actor, reason: "Look again")
    match_and_verify

    get admin_checks_path
    assert_select "#claim-#{a.id}", { text: /Data Quality recommends/, count: 0 }
    assert_select "#claim-#{a.id} .nd-tag", "Waiting for Data Quality"
  end

  test "a claim id too long to exist is a line error, not a crash" do
    paste("12345678901234567890 approve: too long")

    assert_response :unprocessable_content
    assert_select ".nd-alert li", /Line 1: there's no fact 12345678901234567890/
  end

  test "a claim held only by its source's review hold is accepted with Data Quality's approve, unless it would change a person's decision" do
    source = Source.create!(url: "https://www.nrc.gov/test/held.html", source_kind: "hold_dummy", crawl_status: "ok", title: "Held list", content_text: "a quote")
    run = CrawlRun.create!(source_kind: "hold_dummy", stage: "crawl", status: "succeeded", started_at: 1.hour.ago)
    Directory::FactWriter.write(:organization, { name: "Held Fission Co" })
    decided = Organization.create!(name: "Decided Fission Co", verification_status: "verified", verified_by: "human:tosin")
    decided.aliases.create!(alias: "Decided Fission Co")
    held, kept = [ "Held Fission Co", "Decided Fission Co" ].map do |name|
      Candidate.create!(source:, kind: "organization", payload: { "name" => name, "description" => "A new description." }, quote: "a quote", crawl_run: run)
    end
    plugin = DataQuality::Plugins::HoldDummy.new
    DataQuality::Pipeline.run("hold_dummy", plugin:, only: "match")
    DataQuality::Pipeline.run("hold_dummy", plugin:, only: "verify", verifier: Recommend.new)
    assert held.reload.status_needs_review?
    assert_match DataQuality::Plugins::HoldDummy::HOLD, held.notes

    paste("#{held.id} approve: the list names it\n#{kept.reload.id} approve: the list names it")
    get admin_recommendations_path
    assert_select "#rec-#{kept.id}", /would change a record a person decided|already/
    shown = css_select("form[action='#{admin_recommendations_accept_path}'] input[name=shown]").first["value"]
    post admin_recommendations_accept_path, params: { shown: }

    assert held.reload.status_merged?, [ held.notes, flash[:alert], flash[:notice] ].inspect
    assert_not kept.reload.status_merged?, "a person's decision is never overwritten"
  end

  test "a source-held approval isn't accepted once the quote is gone from the source, or when another warning was added" do
    source = Source.create!(url: "https://www.nrc.gov/test/held2.html", source_kind: "hold_dummy", crawl_status: "ok", content_text: "Gone Fission Co and Warned Fission Co.")
    run = CrawlRun.create!(source_kind: "hold_dummy", stage: "crawl", status: "succeeded", started_at: 1.hour.ago)
    gone, warned = [ "Gone Fission Co", "Warned Fission Co" ].map do |name|
      Directory::FactWriter.write(:organization, { name: })
      Candidate.create!(source:, kind: "organization", payload: { "name" => name }, quote: name, crawl_run: run)
    end
    plugin = DataQuality::Plugins::HoldDummy.new
    DataQuality::Pipeline.run("hold_dummy", plugin:, only: "match")
    DataQuality::Pipeline.run("hold_dummy", plugin:, only: "verify", verifier: Recommend.new)
    warned.reload.update_columns(notes: "#{warned.notes}. A newer file exists: check this one against it")
    paste("#{gone.id} approve: named\n#{warned.id} approve: named")
    source.update_columns(content_text: "Warned Fission Co only.")

    get admin_recommendations_path
    assert_select "#rec-#{gone.id}", /quote isn.t in the source any more/
    assert_select "#rec-#{warned.id}", /waiting for a person.s review|checker didn.t recommend/
  end
end
