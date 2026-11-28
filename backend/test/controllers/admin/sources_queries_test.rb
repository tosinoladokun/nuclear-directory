require "test_helper"

# #1029: Sources ran about 530 queries a load in production, a batch of
# lookups per row (each crawler kind and publisher group) and two more per row
# for its last failure. Its queries must not grow with the rows or documents.
class Admin::SourcesQueriesTest < ActionDispatch::IntegrationTest
  # Sources with its nav, as loaded with today's ~45 rows: well under the old per-row cost. The page
  # itself is about 17; the rest are the nav's counts, cached in production but not in tests.
  MAX_QUERIES = 90

  setup do
    sign_in_as users(:admin)
  end

  # Per n: a crawler kind of its own with two documents, a good match run and a later failed crawl;
  # a published company each backs; and a company site and a government page of hand research.
  def add_rows(count, from:)
    count.times do |i|
      n = from + i
      kind = "queries_kind_#{n}"
      company = Organization.create!(name: "Sources Queries #{n}", verification_status: "verified", verified_by: "human:tosin")
      [ "https://kind#{n}.example/a", "https://kind#{n}.example/b" ].each do |url|
        source = Source.create!(url:, source_kind: kind, crawl_status: "ok", fetched_at: 1.hour.ago, content_sha256: "s", content_text: "q")
        Evidence.create!(source:, subject: company, quote: "q", found_by: "crawler")
      end
      CrawlRun.create!(source_kind: kind, stage: "match", status: "succeeded", started_at: 2.hours.ago, stats: { "candidates" => 2, "confirmed" => 2 })
      CrawlRun.create!(source_kind: kind, stage: "crawl", status: "failed", started_at: 1.hour.ago, error: "timeout")
      [ "https://site#{n}.example/", "https://agency#{n}.gov/page" ].each do |url|
        page = Source.create!(url:, source_kind: SourceCatalog::RESEARCH_KIND, crawl_status: "blocked", fetched_at: 1.hour.ago, content_sha256: "s", content_text: "q")
        Evidence.create!(source: page, subject: company, quote: "q", found_by: "crawler")
      end
    end
  end

  # Queries a page load makes, counted by where in the app they come from, so a failure names the call that grew.
  def queries_for(path)
    @sites = Hash.new(0)
    counter = lambda do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/)

      @sites[caller.grep(%r{/app/}).first(3).map { |line| line[%r{app/[^:]+:\d+}] }.join(" < ")] += 1
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
    assert_response :success
    @sites.values.sum
  end

  def grew(before, after) = after.filter_map { |site, n| "#{n - before[site]} more at #{site}" if n > before[site] }.join("; ")

  test "Sources' queries don't grow with its rows and documents, and stay under the cap" do
    add_rows(3, from: 0)
    few = queries_for(admin_sources_path)
    before = @sites
    add_rows(12, from: 3)
    many = queries_for(admin_sources_path)

    assert_operator many, :<=, few + 2, "#{few} queries with 3 kinds, #{many} with 15: a lookup per row again. #{grew(before, @sites)}"
    assert_operator many, :<=, MAX_QUERIES
    # Still what each row shows: its documents, the facts they back, and the last failure.
    assert_select "a[href=?]", admin_source_path(key: "queries_kind_14")
    assert_select "p", /The last read failed: timeout/
  end

  test "a source's own page doesn't grow with the other rows either" do
    add_rows(3, from: 0)
    few = queries_for(admin_source_path(key: "queries_kind_0"))
    add_rows(12, from: 3)
    many = queries_for(admin_source_path(key: "queries_kind_0"))

    assert_operator many, :<=, few + 2, "#{few} queries with 3 kinds, #{many} with 15. #{grew(Hash.new(0), @sites)}"
  end
end
