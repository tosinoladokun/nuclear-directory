require "test_helper"

# PM, 10 Nov: at most 10 new companies to create a day in Tosin's inbox, best-sourced first; the rest wait
# for the next day. Plants and facts aren't counted.
class OwnerInboxCapTest < ActiveSupport::TestCase
  setup do
    @page = Source.create!(url: "https://www.nrc.gov/test/cap.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha", content_text: "q")
    # An earlier batch from this source, so these claims aren't its first (which Data Quality reads).
    first = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
    Candidate.create!(source: @page, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
  end

  # A pending company with a sourced role and its new-company claim, named on `pages` pages.
  def new_company(name, pages: 1)
    company = give_sourced_role(Organization.create!(name:, verification_status: "pending"))
    pages.times.map do |n|
      source = n.zero? ? @page : Source.create!(url: "https://example.com/#{name.parameterize}/#{n}", source_kind: "dummy", crawl_status: "ok",
        content_sha256: "sha", content_text: "q")
      Candidate.create!(source:, crawl_run: @run, kind: "organization", payload: { "name" => name }, quote: "q", status: "matched",
        subject_type: "Organization", subject_id: company.id, proposed_subject: true, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    end
    company
  end

  def shown_names(inbox = OwnerInbox.new)
    inbox.sections["new_record"].map { |entry| Candidate.find(entry.item.candidate_id).payload["name"] }
  end

  test "ten a day, best-sourced first; the rest wait and are counted; decided today counts against the ten" do
    best = new_company("Best Sourced Co", pages: 3)
    11.times { |n| new_company("Plain Co #{n}") }
    inbox = OwnerInbox.new
    names = shown_names(inbox)
    assert_equal 10, names.size
    assert_equal "Best Sourced Co", names.first, "most pages first"
    assert_equal 2, inbox.companies_waiting
    assert_equal 10 + inbox.records.size, inbox.size

    3.times { |n| Organization.find_by!(name: "Plain Co #{n}").verify!(by: "human:tosin") }
    VerificationEvent.where(subject_type: "Organization", to_status: "verified").update_all(created_at: Time.current)
    assert_equal 7, shown_names.size, "three decided today"
    assert_includes shown_names, best.name

    travel 1.day do
      assert_equal 10, shown_names.size, "a new day, ten again"
    end
  end

  test "a company is one slot however many fields its pages give, ranked by distinct pages" do
    spread = give_sourced_role(Organization.create!(name: "Spread Co", verification_status: "pending"))
    4.times do |n|
      source = Source.create!(url: "https://spread.example/#{n}", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha", content_text: "q")
      Candidate.create!(source:, crawl_run: @run, kind: "organization", payload: { "name" => "Spread Co", "hq_city" => "City #{n}" }, quote: "q",
        status: "matched", subject_type: "Organization", subject_id: spread.id, proposed_subject: true, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    end
    new_company("Twice Co", pages: 2)
    10.times { |n| new_company("Plain Co #{n}") }
    inbox = OwnerInbox.new
    assert_equal spread.id, inbox.ranked_companies.first, "four distinct pages"
    assert_equal 10, inbox.shown_companies.size
    assert_equal 2, inbox.companies_waiting
  end

  test "the waiting count covers every pending company, beyond the rows fetched" do
    3.times { |n| give_sourced_role(Organization.create!(name: "Bare Co #{n}", verification_status: "pending")) }
    inbox = OwnerInbox.new
    silence_warnings { OwnerInbox.const_set(:CREATES_A_DAY, 1) }
    total = inbox.pending_company_count
    assert_operator total, :>=, 3
    assert_equal total - 1, OwnerInbox.new.companies_waiting
  ensure
    silence_warnings { OwnerInbox.const_set(:CREATES_A_DAY, 10) }
  end

  test "the most complete come first (website, description, HQ), then the best-sourced" do
    well_sourced = new_company("Many Pages Co", pages: 3)
    complete = new_company("Complete Co")
    complete.update_columns(website: "https://complete.example", description: "Builds reactors.", hq_city: "Austin")
    assert_equal [ complete.id, well_sourced.id ], OwnerInbox.new.ranked_companies.first(2)
  end
end
