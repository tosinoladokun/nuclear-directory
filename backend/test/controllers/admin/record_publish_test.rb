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
    role = @company.organization_roles.sole
    post publish_path, params: { with_added: "1", added: [ "OrganizationRole:#{role.id}" ] }

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

  test "Publish checks the record is still waiting, with the write: one taken off since isn't published" do
    @company.update_columns(verification_status: "unpublished")
    result = DataQuality::Review.publish(type: "Organization", id: @company.id, by: "human:tosin")
    assert_equal [ "it's unpublished now, so it wasn't published" ], result.errors
    assert_equal "unpublished", @company.reload.verification_status
  end

  test "the preview counts only links whose other end is public too" do
    live = Organization.create!(name: "Live Partner", verification_status: "verified", verified_by: "human:tosin")
    hidden = Organization.create!(name: "Waiting Partner", verification_status: "pending")
    [ live, hidden ].each { |other| Relationship.create!(from_organization: @company, to_organization: other, relationship_type: "supplies", verification_status: "verified", verified_by: "human:tosin") }

    assert_equal 1, DataQuality::Review.publish_plan(type: "Organization", id: @company.id).goes_live_with
  end

  test "Publish takes only the added facts the preview listed: one added since stops it" do
    shown = [ "OrganizationRole:#{@company.organization_roles.sole.id}" ]
    Technology.create!(key: "smr", name: "Small modular reactor")
    assert DataQuality::Review.add_company_fact(organization_id: @company.id, kind: "technology", key: "smr", url: "https://example.com/smr",
      quote: "It designs an SMR.", by: "human:tosin").ok?

    result = DataQuality::Review.publish(type: "Organization", id: @company.id, by: "human:tosin", with_added: shown)
    assert_equal [ "what was added with it changed since the preview; check it again" ], result.errors
    assert_equal "pending", @company.reload.verification_status
  end

  test "an added fact decided since the preview isn't published with it, and nothing is" do
    role = @company.organization_roles.sole
    shown = [ "OrganizationRole:#{role.id}" ]
    role.reject!(by: "human:tosin", reason: "Wrong role")

    result = DataQuality::Review.publish(type: "Organization", id: @company.id, by: "human:tosin", with_added: shown)
    assert_not result.ok?
    assert_equal "pending", @company.reload.verification_status
    assert_equal "rejected", role.reload.verification_status
  end
end
