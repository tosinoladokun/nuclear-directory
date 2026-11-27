require "test_helper"

# #1008: Today ran about 2,500 queries a load in production, one batch of
# lookups per waiting claim; quick clicks through decisions, each redirecting
# back to it, ran the server out of memory. Its queries must not grow with the
# number of claims, and a decision clicked on the page returns only the row to
# remove.
class Admin::InboxQueriesTest < ActionDispatch::IntegrationTest
  # Today with its nav, as loaded with today's volume: well under the old per-claim cost.
  MAX_QUERIES = 120

  setup do
    sign_in_as users(:admin)
    @page = Source.create!(url: "https://www.nrc.gov/test/queries.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha", content_text: "q")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
  end

  # Per company: its Create, a role, Data Quality's approve and a checked website claim riding with it;
  # and a change on a published company.
  def add_companies(count, from:)
    count.times do |i|
      n = from + i
      company = give_sourced_role(Organization.create!(name: "Queries Fission #{n}", verification_status: "pending"))
      create = claim(company, { "name" => company.name }, proposed_subject: true)
      site = claim(company, { "name" => company.name, "website" => "https://fission#{n}.example" })
      DataQuality::Recommendations.record("#{create.id} approve: on the NRC page\n#{site.id} approve: its own site", by: "human:dq")
      DqAction.create!(candidate: create, action: "new", reason: "r", before: {}, created: [], by: DataQuality::Matching::BY)
      # Published two days ago: today's would use up the day's Creates (OwnerInbox::CREATES_A_DAY), leaving no rows to show.
      published = travel_to(2.days.ago) { Organization.create!(name: "Queries Utility #{n}", hq_city: "Bethesda", verification_status: "verified", verified_by: "human:tosin") }
      published.aliases.create!(alias: published.name)
      claim(published, { "name" => published.name, "hq_city" => "Rockville" })
      # A link between them, and a lead Tosin added that found the new company (Copilot).
      link = Relationship.create!(from_organization: published, to_organization: company, relationship_type: "invests_in", verification_status: "pending")
      Candidate.create!(source: @page, crawl_run: @run, kind: "relationship", quote: "q", status: "matched", subject_type: "Relationship", subject_id: link.id,
        payload: { "from_organization" => { "name" => published.name }, "to_organization" => { "name" => company.name }, "relationship_type" => "invests_in" },
        ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
      Lead.create!(kind: "company", name: company.name, normalized_name: Lead.normalize(company.name), status: "added", candidate: create,
        first_seen_on: Date.current, last_seen_on: Date.current,
        sources: [ { "label" => CompanySuggestion::LABEL, "first" => Date.current.iso8601, "last" => Date.current.iso8601, "times" => 1 } ])
    end
  end

  def claim(company, payload, **options)
    Candidate.create!(source: @page, crawl_run: @run, kind: "organization", payload:, quote: "q", status: "matched",
      subject_type: "Organization", subject_id: company.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha", **options)
  end

  def queries_for(path)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
    assert_response :success
    count
  end

  def queries_for_inbox = queries_for(admin_inbox_path)

  test "Today's queries don't grow with the claims waiting, and stay under the cap" do
    add_companies(3, from: 0)
    few = queries_for_inbox
    add_companies(12, from: 3)
    many = queries_for_inbox

    assert_operator many, :<=, few + 5, "#{few} queries with 3 companies, #{many} with 15: a lookup per claim again"
    assert_operator many, :<=, MAX_QUERIES
  end

  # Every admin page's nav counts Today's waiting facts: on 27 Nov a news item took 1,861 queries for it (Infra).
  test "another admin page's nav count of Today doesn't grow with the claims either (a news item)" do
    item = NewsItem.create!(url: "https://example.org/news/queries", title: "Vogtle exemption", headline: "Vogtle exemption", publisher: "NRC",
      published_on: Date.new(2026, 11, 18), verification_status: "verified", verified_by: "human:tosin", verified_at: Time.current)
    add_companies(3, from: 0)
    few = queries_for(admin_news_item_path(id: item.id))
    add_companies(12, from: 3)
    many = queries_for(admin_news_item_path(id: item.id))

    assert_operator many, :<=, few + 5, "#{few} queries with 3 companies, #{many} with 15"
    assert_operator many, :<=, MAX_QUERIES
  end

  test "a decision clicked on the page removes only its row and shows the message, without rebuilding the inbox" do
    add_companies(1, from: 0)
    create = Candidate.find_by!(proposed_subject: true, payload: { "name" => "Queries Fission 0" })

    post admin_inbox_decide_path(create.id, "no"), params: { ids: [ create.id ] }, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=remove][target=inbox-item-#{create.id}]"
    assert_select "turbo-stream[action=update][target=admin-flash] template", /Said no/
    assert_select "turbo-stream[action=update][target=admin-flash] template form[action=?]", admin_inbox_undo_path
    assert create.reload.status_rejected?
  end

  test "without Turbo, a decision still redirects to Today with its message" do
    add_companies(1, from: 0)
    create = Candidate.find_by!(proposed_subject: true, payload: { "name" => "Queries Fission 0" })

    post admin_inbox_decide_path(create.id, "no"), params: { ids: [ create.id ] }

    assert_redirected_to admin_inbox_path
    assert_equal "Said no. It's kept in Leads.", flash[:notice]
  end
end
