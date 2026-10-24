require "test_helper"

# A news item waiting (#137) reads in plain words on Checks and its fact page.
class Admin::NewsClaimsChecksTest < ActionDispatch::IntegrationTest
  test "a waiting news item shows on Checks and on its company's page" do
    sign_in_as users(:admin)
    company = Organization.create!(name: "Acme Fission").tap { |c| c.verify!(by: "human:tosin") }
    source = Source.create!(url: "https://www.world-nuclear-news.org/articles/acme", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    claim = Candidate.create!(source:, kind: "news_item", quote: "Acme Fission files a permit.", status: "matched", subject_type: "Organization",
      subject_id: company.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha",
      payload: { "url" => source.url, "title" => "Acme Fission files permit", "publisher" => "World Nuclear News", "published_on" => "2026-10-20",
        "about" => [ { "name" => "Acme Fission", "type" => "organization" } ], "mentions" => [ [ "Organization", company.id ] ] })

    get admin_checks_path
    assert_response :success
    assert_select "#claim-#{claim.id}"
    get admin_fact_path(type: "Organization", id: company.id, claim: claim.id)
    assert_response :success
    assert_match "Acme Fission files permit", response.body
  end
end
