require "test_helper"

# PM, 30 Oct: a short headline for Latest, the title when there's none.
class NewsHeadlineTest < ActiveSupport::TestCase
  def item(**fields) = NewsItem.new(url: "https://www.federalregister.gov/d/2026-1", title: "Long docket title, Docket No. 50-397; NRC-2026-0001", published_on: Date.current, **fields)

  test "80 characters at most, in the model and the database; Latest shows it, else the title" do
    assert item(headline: "x" * 80).valid?
    assert_not item(headline: "x" * 81).valid?
    assert_equal "Columbia licence renewal", item(headline: " Columbia licence renewal ").display_title
    assert_equal "Long docket title, Docket No. 50-397; NRC-2026-0001", item.display_title
    saved = item.tap(&:save!)
    assert_raises(ActiveRecord::StatementInvalid) { NewsItem.transaction(requires_new: true) { saved.update_columns(headline: "x" * 81) } }
  end

  test "a news claim's headline is written on approval" do
    company = Organization.create!(name: "Headline Co", verification_status: "verified", verified_by: "human:tosin")
    company.aliases.create!(alias: "Headline Co")
    page = Source.create!(url: "https://www.federalregister.gov/d/2026-2", source_kind: "web_page", crawl_status: "ok", content_sha256: "s",
      content_text: "Headline Co licence notice.")
    claim = Candidate.create!(source: page, kind: "news_item", status: "matched", quote: "Headline Co licence notice.", subject_type: "Organization", subject_id: company.id,
      payload: { "url" => page.url, "title" => "Notice of licence, Docket No. 52-001", "headline" => "Headline Co licence notice", "published_on" => "2026-10-20",
        "summary" => "s", "about" => [ { "name" => "Headline Co", "type" => "organization" } ], "mentions" => [ [ "Organization", company.id ] ] })
    assert DataQuality::Review.approve([ claim.id ], by: "human:tosin").sole.ok?
    assert_equal "Headline Co licence notice", NewsItem.find_by!(url: page.url).headline
  end
end
