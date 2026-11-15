require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #760: a new-company claim with one quote per field. The company is found
# with everything the claim says; each field becomes its own claim from its
# own page, follows its claim's company, and goes with Tosin's one Create once
# it's checked against that page.
class Admin::FieldEvidenceTest < ActionDispatch::IntegrationTest
  NAME_QUOTE = "Fresh Fission LLC designs microreactors.".freeze
  HQ_QUOTE = "Fresh Fission LLC, 100 Main St, Austin, Texas.".freeze

  setup do
    sign_in_as users(:admin)
    first = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
    @about = Source.create!(url: "https://freshfission.example/about", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: NAME_QUOTE)
    Candidate.create!(source: @about, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    @contact = Source.create!(url: "https://freshfission.example/contact", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: HQ_QUOTE)
  end

  def hq = { "fields" => %w[hq_city hq_state], "quote" => HQ_QUOTE, "source_url" => @contact.url }

  def claim(evidence = [ hq ], status: "new", **extra)
    Candidate.create!(source: @about, crawl_run: @run, kind: "organization", status:, quote: NAME_QUOTE,
      payload: { "name" => "Fresh Fission LLC", "description" => "Designs microreactors.", "hq_city" => "Austin", "hq_state" => "TX",
        "evidence" => evidence, **extra })
  end

  def match! = DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
  def field_of(main) = DataQuality::FieldEvidence.fields_of(main.id).sole
  # As the verifier leaves a claim it agreed with.
  def checked!(*claims) = Candidate.where(id: claims.map(&:id)).update_all(ai_recommendation: "recommend_publish", ai_source_sha256: "sha")

  test "split after the company is found: each field its own claim from its own page, on the main claim's company" do
    main = claim
    match!
    field = field_of(main)
    assert_equal({ "name" => "Fresh Fission LLC", "description" => "Designs microreactors." }, main.reload.payload)
    assert_equal [ @contact.id, HQ_QUOTE, { "name" => "Fresh Fission LLC", "field_of" => main.id, "hq_city" => "Austin", "hq_state" => "TX" } ],
      field.reload.values_at(:source_id, :quote, :payload)
    assert_equal [ "matched", main.subject_id ], field.values_at(:status, :subject_id)
    assert_no_match(/field of/i, DataQuality::Claim.describe(field), "bookkeeping isn't described to the checker")
  end

  test "the website still finds an existing company before it's split off" do
    known = Organization.create!(name: "FF Holdings", website: "https://freshfission.example", domain: "freshfission.example",
      verification_status: "verified", verified_by: "human:tosin")
    main = claim([ { "fields" => %w[website], "quote" => HQ_QUOTE, "source_url" => @contact.url } ], "website" => "https://freshfission.example")
    match!
    assert_equal known.id, main.reload.subject_id, main.notes
    assert_equal known.id, field_of(main).subject_id
  end

  test "malformed evidence, or a page we haven't read, goes to a person; nothing is split" do
    cases = [
      [ [ { "fields" => %w[ticker], "quote" => "q", "source_url" => @contact.url } ], "can't carry: ticker" ],
      [ [ hq, hq ], "a field twice: hq_city" ],
      [ [ hq.merge("quote" => "") ], "needs a quote and a source_url" ],
      [ [ hq.merge("source_url" => "https://never-read.example/hq") ], "hasn't been read yet" ]
    ]
    cases.each do |evidence, why|
      c = claim(evidence)
      match!
      assert_equal "needs_review", c.reload.status
      assert_match why, c.notes
      assert_empty DataQuality::FieldEvidence.fields_of(c.id)
    end
  end

  test "a field claim never finds a company by itself: it waits while its claim waits" do
    main = claim
    match!
    field = field_of(main)
    main.update_columns(status: "needs_review", subject_type: nil, subject_id: nil)
    DataQuality::FieldEvidence.follow!(main)
    assert_equal [ "needs_review", nil, DataQuality::FieldEvidence::WAITING ], field.reload.values_at(:status, :subject_id, :notes)
    field.update_columns(status: "new")
    match!
    assert_nil field.reload.subject_id
  end

  test "one Create writes the company and every checked field, each field's quote marked for its fields" do
    main = claim
    match!
    company = Organization.find(main.reload.subject_id)
    give_sourced_role(company)
    checked!(main, field_of(main))

    get admin_inbox_path
    field = field_of(main)
    assert_select "#inbox-item-#{field.id}", 0, "not a row of its own"
    assert_select "#field-claim-#{field.id}", /Headquarters city: Austin, Headquarters state: TX/

    entry = OwnerInbox.new.sections["new_record"].find { |e| e.item.candidate_id == main.id }
    assert_includes entry.ids, field.id
    post admin_inbox_decide_path(main.id, "yes"), params: { ids: entry.ids }
    company.reload
    assert company.verified?
    assert_equal [ "Austin", "TX", "Designs microreactors." ], company.values_at(:hq_city, :hq_state, :description)
    assert_equal [ [ @contact.id, %w[hq_city hq_state] ] ], company.evidence.where(quote: HQ_QUOTE).pluck(:source_id, :fields)
  end

  test "a field not yet checked against its page stays out of Create, and approve refuses it" do
    main = claim
    match!
    give_sourced_role(Organization.find(main.reload.subject_id))
    checked!(main)
    field = field_of(main)
    entry = OwnerInbox.new.sections["new_record"].find { |e| e.item.candidate_id == main.id }
    assert_not_includes entry.ids, field.id
    result = DataQuality::Review.approve([ field.id ], by: "human:tosin").sole
    assert_not result.ok?
    assert_match "isn't checked against its own page", result.errors.to_sentence
  end

  test "a field Data Quality said no to stays out of its Create, but he can still approve it on its own" do
    main = claim
    match!
    give_sourced_role(Organization.find(main.reload.subject_id))
    field = field_of(main)
    checked!(main, field)
    DataQuality::Recommendations.record("#{field.id} reject: a branch office", by: "human:dq")
    entry = OwnerInbox.new.sections["new_record"].find { |e| e.item.candidate_id == main.id }
    assert_not_includes entry.ids, field.id
    assert DataQuality::Review.approve([ field.id ], by: "human:tosin").sole.ok?, "his explicit approve still works"
  end

  test "Yes to all creates the company with its checked fields, and a changed field invalidates what was shown" do
    main = claim
    match!
    company = Organization.find(main.reload.subject_id)
    give_sourced_role(company)
    field = field_of(main)
    checked!(main, field)
    DataQuality::Recommendations.record("#{main.id} approve: their page", by: "human:dq")
    other = give_sourced_role(Organization.create!(name: "Other Fission", verification_status: "pending"))
    second = Candidate.create!(source: @about, crawl_run: @run, kind: "organization", status: "matched", quote: NAME_QUOTE, payload: { "name" => "Other Fission" },
      subject_type: "Organization", subject_id: other.id, proposed_subject: true, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    DataQuality::Recommendations.record("#{second.id} approve: their page", by: "human:dq")

    shown = OwnerInbox.new.yes_all_fingerprint
    field.update_columns(quote: "#{HQ_QUOTE} ")
    post admin_inbox_yes_all_path, params: { shown: }
    assert_not company.reload.verified?, "the field changed since it was shown"
    field.update_columns(quote: HQ_QUOTE)

    post admin_inbox_yes_all_path, params: { shown: OwnerInbox.new.yes_all_fingerprint }
    assert_equal [ "Austin", "TX" ], company.reload.values_at(:hq_city, :hq_state)
    assert company.verified?
  end

  test "Data Quality's new splits an unsplit claim, puts its fields on the new company, and Undo puts them back" do
    main = claim(status: "needs_review")
    DataQuality::Matching.apply([ { "id" => main.id, "action" => "new", "reason" => "a new licensee" } ])
    field = field_of(main)
    company_id = main.reload.subject_id
    assert_equal [ "matched", company_id ], field.reload.values_at(:status, :subject_id)

    assert_nil DataQuality::Matching.undo(DqAction.last.id)
    assert_equal [ "needs_review", nil ], field.reload.values_at(:status, :subject_id)
    assert_equal "rejected", Organization.find(company_id).verification_status
    assert_nil main.reload.payload["evidence"], "it stays split"
  end

  test "a claim moved to another company takes its open fields along, and says where they were (for Undo)" do
    wrong = Organization.create!(name: "Other Brand", domain: "freshfission.example", verification_status: "verified", verified_by: "human:tosin")
    main = claim([ hq ], "website" => "https://freshfission.example")
    match!
    field = field_of(main)
    assert_equal [ wrong.id, wrong.id ], [ main.reload.subject_id, field.reload.subject_id ]
    right = Organization.create!(name: "Fresh Fission LLC", verification_status: "pending")
    main.update_columns(subject_id: right.id)
    befores = DataQuality::FieldEvidence.follow!(main.reload)
    assert_equal right.id, field.reload.subject_id
    assert_equal [ [ field.id, wrong.id ] ], befores.map { |b| b.values_at("id", "subject_id") }
    DataQuality::FieldEvidence.restore!(befores)
    assert_equal wrong.id, field.reload.subject_id
  end
end
