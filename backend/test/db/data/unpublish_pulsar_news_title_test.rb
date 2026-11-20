require "test_helper"
load Rails.root.join("db/data/20261120200000_unpublish_pulsar_news_title.rb")

# Data Quality, 20 Nov: the non-nuclear pulsar news item comes off, pinned on its id and exact title; anything else
# about it is left and said.
class UnpublishPulsarNewsTitleTest < ActiveSupport::TestCase
  setup do
    NewsItem.find_by(id: 70)&.destroy!
    @news = NewsItem.create!(id: 70, url: "https://science.nasa.gov/open-science/fermi-data-pulsar-discovery/", title: UnpublishPulsarNewsTitle::TITLE,
      headline: "NASA Fermi data helps team develop faster pulsar search method", published_on: Date.new(2026, 11, 19), publisher: "NASA",
      verification_status: "verified", verified_by: "human:tosin", verified_at: Time.utc(2026, 11, 19))
  end

  def run_it = UnpublishPulsarNewsTitle.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "takes it off as Tosin's decision with the reason; a rerun says it's already off" do
    run_it
    assert_equal "unpublished", @news.reload.verification_status
    assert_match "Not nuclear", VerificationEvent.where(subject: @news).order(:id).last.reason.to_s
    assert_nothing_raised { run_it }
  end

  test "the old pin (the headline) is not the title: the item is found by its real title" do
    assert_not_equal "NASA Fermi data helps team develop faster pulsar search method", UnpublishPulsarNewsTitle::TITLE
    assert_equal UnpublishPulsarNewsTitle::TITLE, @news.title
  end

  test "a changed title or a person's decision is left as it is, never a stopped deploy" do
    @news.update_columns(title: "Something else")
    assert_nothing_raised { run_it }
    assert_equal "verified", @news.reload.verification_status
  end

  test "another news item is never touched" do
    other = NewsItem.create!(url: "https://example.com/other", title: "Other nuclear news", published_on: Date.new(2026, 11, 19), publisher: "Other",
      verification_status: "verified", verified_by: "human:tosin", verified_at: Time.utc(2026, 11, 19))
    run_it
    assert_equal "verified", other.reload.verification_status
  end
end
