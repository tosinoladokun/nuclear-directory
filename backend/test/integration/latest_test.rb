require "test_helper"
require_relative "../support/directory_builders"

# "Latest" (#137): up to three approved news items on a company or plant page, newest first; date, headline, source
# domain linking out. Only items a person approved, about a published record. No news page.
class LatestTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  def news(about, title, on, url: "https://www.example.org/#{title.parameterize}", by: "human:tosin")
    item = NewsItem.create!(url:, title:, published_on: on, publisher: "Example", verification_status: "verified", verified_by: by, verified_at: Time.current)
    NewsMention.create!(news_item: item, subject: about)
    item
  end

  test "a company shows its three newest approved items, newest first, each linking to its source" do
    holtec = cite!(company("Holtec International"))
    news(holtec, "Oldest item", Date.new(2026, 8, 1))
    news(holtec, "Second item", Date.new(2026, 9, 2))
    news(holtec, "Third item", Date.new(2026, 9, 20), url: "https://news.holtec.com/third")
    news(holtec, "Newest item", Date.new(2026, 10, 15))
    news(holtec, "Agent-approved item", Date.new(2026, 10, 20), by: "agent:triage")

    get company_path(slug: holtec.slug)

    assert_select "#latest-heading", /Latest\s*3/
    assert_equal [ "Newest item", "Third item", "Second item" ], css_select("#latest .nd-news__title").map { |node| node.text.strip }
    assert_select "#latest .nd-news__date", "2026-10-15"
    assert_select "#latest a.nd-news__src[href='https://news.holtec.com/third'][rel~=noopener][target=_blank]", /news\.holtec\.com/
    assert_select "#latest", text: /Agent-approved|Oldest/, count: 0
    assert_select "nav a[href='#latest']", /Latest/
  end

  test "each item says what it means in one plain line, 160 characters at most" do
    holtec = cite!(company("Holtec International"))
    long = "Holtec asks the NRC to let it start Palisades again. " * 6
    item = news(holtec, "Holtec exemption request", Date.new(2026, 10, 15))
    item.update!(summary: long)
    other = news(holtec, "No summary yet", Date.new(2026, 10, 1))

    get company_path(slug: holtec.slug)

    summary = css_select("#latest .nd-news__summary").map { |node| node.text.strip }
    assert_equal 1, summary.size, "an item with no summary shows none, never a guess"
    assert_operator summary.first.length, :<=, 160
    assert_match(/\AHoltec asks the NRC/, summary.first)
    assert other
  end

  test "a plant shows its site's news; a page with none has no Latest section" do
    vogtle = cite!(plant("Plant Vogtle", facility_type: "power_reactor", status: "operating"))
    news(vogtle, "Unit 4 reaches full power", Date.new(2026, 7, 29))
    get plant_path(slug: vogtle.slug)
    assert_select "#latest .nd-news__title", "Unit 4 reaches full power"

    quiet = cite!(company("Quiet Co"))
    get company_path(slug: quiet.slug)
    assert_select "#latest", 0
  end

  test "news about an unpublished company is not shown" do
    hidden = company("Hidden Co", verified: false)
    news(hidden, "Hidden news", Date.new(2026, 10, 1))
    assert_empty NewsItem.latest_for(hidden)
    assert_empty NewsItem.published.where(title: "Hidden news")
  end
end
