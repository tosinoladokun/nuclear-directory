require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #760: a new-company claim with one quote per field. Each field becomes its
# own claim from its own source, and Tosin's one Create takes them together.
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

  def claim(evidence)
    Candidate.create!(source: @about, crawl_run: @run, kind: "organization", status: "new", quote: NAME_QUOTE,
      payload: { "name" => "Fresh Fission LLC", "description" => "Designs microreactors.", "hq_city" => "Austin", "hq_state" => "TX",
        "evidence" => evidence })
  end

  def match! = DataQuality::Stages::Match.call(plugin: DummyPlugin.new)

  test "matching splits the evidence: each field its own claim from its own page; the main claim keeps the rest" do
    main = claim([ { "fields" => %w[hq_city hq_state], "quote" => HQ_QUOTE, "source_url" => @contact.url } ])
    match!
    field = DataQuality::FieldEvidence.fields_of(main.id).sole
    assert_equal({ "name" => "Fresh Fission LLC", "description" => "Designs microreactors." }, main.reload.payload)
    assert_equal [ @contact.id, HQ_QUOTE, { "name" => "Fresh Fission LLC", "field_of" => main.id, "hq_city" => "Austin", "hq_state" => "TX" } ],
      field.reload.values_at(:source_id, :quote, :payload)
    assert_equal main.subject_id, field.subject_id, "both on the new company"
  end

  test "evidence for an unknown field, a field named twice, or without its quote goes to a person" do
    hq = ->(quote = "q") { { "fields" => %w[hq_city], "quote" => quote, "source_url" => @contact.url } }
    cases = [
      [ [ { "fields" => %w[ticker], "quote" => "q", "source_url" => @contact.url } ], "can't carry: ticker" ],
      [ [ hq.call, hq.call ], "a field twice: hq_city" ],
      [ [ hq.call("") ], "needs a quote and a source_url" ]
    ]
    cases.each do |evidence, why|
      c = claim(evidence)
      match!
      assert_equal "needs_review", c.reload.status
      assert_match why, c.notes
      assert_empty DataQuality::FieldEvidence.fields_of(c.id)
    end
  end

  test "one Create writes the company and every field, each field's evidence from its own page" do
    main = claim([ { "fields" => %w[hq_city hq_state], "quote" => HQ_QUOTE, "source_url" => @contact.url } ])
    match!
    company = Organization.find(main.reload.subject_id)
    give_sourced_role(company)
    # As the verifier leaves them.
    Candidate.where(id: [ main.id, *DataQuality::FieldEvidence.fields_of(main.id).ids ]).update_all(ai_recommendation: "recommend_publish", ai_source_sha256: "sha")

    get admin_inbox_path
    assert_select "#inbox-item-#{main.id}"
    field = DataQuality::FieldEvidence.fields_of(main.id).sole
    assert_select "#inbox-item-#{field.id}", 0, "not a row of its own"
    assert_select "#field-claim-#{field.id}", /Headquarters city: Austin, Headquarters state: TX/

    entry = OwnerInbox.new.sections["new_record"].find { |e| e.item.candidate_id == main.id }
    post admin_inbox_decide_path(main.id, "yes"), params: { ids: entry.ids }
    company.reload
    assert company.verified?
    assert_equal [ "Austin", "TX", "Designs microreactors." ], company.values_at(:hq_city, :hq_state, :description)
    assert_equal [ @contact.id ], company.evidence.where(quote: HQ_QUOTE).pluck(:source_id)
    assert_equal [ @about.id ], company.evidence.where(quote: NAME_QUOTE).pluck(:source_id)
  end

  test "Yes to all creates the company with its fields too" do
    main = claim([ { "fields" => %w[hq_city hq_state], "quote" => HQ_QUOTE, "source_url" => @contact.url } ])
    match!
    company = Organization.find(main.reload.subject_id)
    give_sourced_role(company)
    Candidate.where(id: [ main.id, *DataQuality::FieldEvidence.fields_of(main.id).ids ]).update_all(ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    other = give_sourced_role(Organization.create!(name: "Other Fission", verification_status: "pending"))
    second = Candidate.create!(source: @about, crawl_run: @run, kind: "organization", status: "matched", quote: NAME_QUOTE, payload: { "name" => "Other Fission" },
      subject_type: "Organization", subject_id: other.id, proposed_subject: true, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    DataQuality::Recommendations.record("#{main.id} approve: their page\n#{second.id} approve: their page", by: "human:dq")

    post admin_inbox_yes_all_path, params: { shown: DataQuality::Recommendations.fingerprint(OwnerInbox.new.checked_items) }
    assert_equal [ "Austin", "TX" ], company.reload.values_at(:hq_city, :hq_state)
    assert company.verified?
  end

  test "Data Quality's new on a claim whose name matched nothing puts its field claims on the new company too" do
    main = claim([ { "fields" => %w[hq_city hq_state], "quote" => HQ_QUOTE, "source_url" => @contact.url } ])
    main.update!(status: "needs_review", payload: main.payload)
    assert_nil DataQuality::FieldEvidence.split!(main)
    DataQuality::Matching.apply([ { "id" => main.id, "action" => "new", "reason" => "a new licensee" } ])
    field = DataQuality::FieldEvidence.fields_of(main.id).sole
    assert_equal [ "matched", main.reload.subject_id ], field.reload.values_at(:status, :subject_id)
  end
end
