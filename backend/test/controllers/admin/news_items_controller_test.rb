require "test_helper"

# Editing a news item's text from the admin (#863): reason, history, undo.
class Admin::NewsItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    @item = NewsItem.create!(url: "https://example.org/news/1", title: "Westinghouse; Vogtle; Exemption Request", headline: "Westinghouse asks for an exemption",
      summary: "Old summary.", publisher: "Federal Register (NRC)", published_on: Date.new(2026, 11, 18), verification_status: "verified", verified_by: "human:tosin", verified_at: Time.current)
  end

  test "finds it, edits its headline, summary and date with a reason, and keeps its status" do
    get admin_news_items_path(q: "exemption")
    assert_select "nav a[href=?]", admin_news_items_path
    assert_select "a[href=?]", admin_news_item_path(id: @item.id)

    patch admin_news_item_path(id: @item.id), params: { values: { headline: "Vogtle exemption request", summary: "New summary.", published_on: "2026-11-17" }, note: "Clearer headline" }
    assert_redirected_to admin_news_item_path(id: @item.id)
    @item.reload
    assert_equal [ "Vogtle exemption request", "New summary.", Date.new(2026, 11, 17), "verified" ], [ @item.headline, @item.summary, @item.published_on, @item.verification_status ]
    event = @item.verification_events.order(:id).last
    assert_equal [ "Clearer headline", [ "Westinghouse asks for an exemption", "Vogtle exemption request" ] ], [ event.reason, event.changed_values["headline"] ]

    get admin_news_item_path(id: @item.id)
    assert_select "li", text: /Clearer headline/
  end

  test "a reason is required, and only the text fields can be changed" do
    patch admin_news_item_path(id: @item.id), params: { values: { headline: "No reason" }, note: "" }
    assert_response :unprocessable_entity
    patch admin_news_item_path(id: @item.id), params: { values: { url: "https://evil.example" }, note: "x" }
    assert_equal "https://example.org/news/1", @item.reload.url
    assert_equal "Westinghouse asks for an exemption", @item.headline
  end

  test "undo puts back the text from before the last edit, as a new recorded edit" do
    patch admin_news_item_path(id: @item.id), params: { values: { headline: "Wrong headline" }, note: "Typo" }
    post admin_news_item_undo_path(id: @item.id)
    assert_redirected_to admin_news_item_path(id: @item.id)
    assert_equal "Westinghouse asks for an exemption", @item.reload.headline
    assert_equal "Undo: Typo", @item.verification_events.order(:id).last.reason
  end
end
