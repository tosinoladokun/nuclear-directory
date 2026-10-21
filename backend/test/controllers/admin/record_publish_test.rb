require "test_helper"

# Publish (#202): a record not yet public, from its page: where it will
# appear, then Publish, with what was added by hand with it if ticked.
class Admin::RecordPublishTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    Role.create!(key: "reactor_vendor", name: "Reactor developer")
    added = DataQuality::Review.add_record(kind: "organization", name: "Aalo Atomics", role: "reactor_vendor", by: "human:tosin",
      url: "https://example.com/aalo", quote: "Aalo Atomics is building the Aalo-X reactor.")
    assert added.ok?, added.errors.to_sentence
    @company = Organization.find(added.ref.id)
  end

  def publish_path = admin_record_publish_path(type: "Organization", id: @company.id)

  test "a record not yet public has Publish; the preview says where it appears and offers what was added with it" do
    get admin_record_path(type: "Organization", id: @company.id)
    assert_select "a[href^=?]", publish_path, text: "Publish"

    get publish_path
    assert_select ".nd-panel", /Appears on: its page, search, the sitemap, category lists.*0 approved facts/m
    assert_select "input[name=with_added][checked]"
    assert_select "label", /Also publish what you added with it by hand: Reactor developer/
  end

  test "Publish puts it on the site with what was added with it, as the admin" do
    post publish_path, params: { with_added: "1" }

    assert_redirected_to admin_record_path(type: "Organization", id: @company.id)
    assert_equal "Published.", flash[:notice]
    assert Organization.published.exists?(@company.id)
    assert @company.organization_roles.sole.verified?
    assert_equal [ "human:tosin", "Published" ], @company.reload.verification_events.order(:id).last.slice(:by, :reason).values
  end

  test "unticked, what was added with it stays waiting" do
    post publish_path

    assert Organization.published.exists?(@company.id)
    assert @company.organization_roles.sole.pending?
  end

  test "a record already public, or taken off, has nothing to publish here" do
    post publish_path
    get publish_path
    assert_redirected_to admin_record_path(type: "Organization", id: @company.id)
    assert_match "isn't waiting to be published", flash[:alert]
  end
end
