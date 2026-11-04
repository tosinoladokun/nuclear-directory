require "test_helper"

# PM, 3 Nov (speed): a page's first build doesn't load each source or each category one query at a time.
class PageQueriesTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze

  def queries_for(path)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
    assert_response :success
    count
  end

  def company_with_sources(slug, sources)
    company = Organization.create!(name: slug.titleize, slug:, description: "Builds reactors.", verification_status: "verified", verified_by: BY)
    sources.times do |n|
      page = Source.create!(url: "https://example.com/#{slug}/#{n}", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t")
      Evidence.create!(subject: company, source: page, quote: "t #{n}", found_by: "human")
    end
  end

  test "a company's own sources load together: more sources, no more queries" do
    %w[warm-up-co one-source-co].each { |slug| company_with_sources(slug, 1) }
    company_with_sources("six-source-co", 6)
    queries_for("/companies/warm-up-co")
    assert_equal queries_for("/companies/one-source-co"), queries_for("/companies/six-source-co")
  end
end
