require "test_helper"

# Removed (#166): everything off the site now, newest first, with the
# decision that took it off, and Put back where it applies.
class Admin::RemovedTest < ActionDispatch::IntegrationTest
  BY = "human:tosin"
  VERIFIED = { verification_status: "verified", verified_by: BY }.freeze

  setup do
    sign_in_as users(:admin)
    @taken = Organization.create!(name: "Taken Off Co", **VERIFIED)
    Evidence.create!(subject: @taken, source: sources(:press_release), quote: "Taken Off Co", found_by: "human")
    @taken.unpublish!(by: BY, reason: "Not nuclear")
    @kept = Organization.create!(name: "Kept Fission Co", **VERIFIED)
    @duplicate = Organization.create!(name: "Duplicate Fission Co", **VERIFIED)
    Directory::FactWriter.merge_organization(from_id: @duplicate.id, into_id: @kept.id, by: BY, reason: "Same company")
    other = Organization.create!(name: "Other Co", **VERIFIED)
    @link = Relationship.create!(from_organization: @kept, to_organization: other, relationship_type: "supplies")
    DataQuality::Review.reject_fact(type: "Relationship", id: @link.id, by: BY, reason: "A memorandum, not supply")
  end

  test "each removed record with its kind, why, reason, who and when, newest first; tabs count each kind" do
    get admin_removed_path

    assert_select "h1", /Removed\s+3/
    names = css_select("tbody tr td:first-child").map { |td| td.text.squish }
    assert_equal [ "Kept Fission Co supplies Other Co", "Duplicate Fission Co", "Taken Off Co" ], names
    assert_select "#row-Organization-#{@taken.id}", /Company\s+· Taken off.*Not nuclear.*tosin/m
    assert_select "#row-Organization-#{@duplicate.id}", /Merged.*into Kept Fission Co.*Same company/m
    assert_select "#row-Organization-#{@duplicate.id} a[href^=?]", admin_record_path(type: "Organization", id: @kept.id), text: "Kept Fission Co"
    assert_select "#row-Relationship-#{@link.id}", /Deal\s+· Rejected.*A memorandum, not supply/m
    assert_select ".nd-fchip", /Taken off\s+1/
    assert_select ".nd-fchip", /Merged\s+1/
    assert_select ".nd-fchip", /Rejected\s+1/

    get admin_removed_path(tab: "merged")
    assert_select "tbody tr", 1
  end

  test "Put back only on what was taken off; once back, it's off the list" do
    get admin_removed_path
    assert_select "#row-Organization-#{@taken.id} button", "Put back"
    assert_select "#row-Organization-#{@duplicate.id} button", 0, "a merge's facts moved to the record kept"
    assert_select "#row-Relationship-#{@link.id} button", 0

    post admin_fact_republish_path(type: "Organization", id: @taken.id), params: { next: admin_removed_path }
    assert_redirected_to admin_removed_path
    assert @taken.reload.verified?, flash.to_h.inspect
    follow_redirect!
    assert_select "#row-Organization-#{@taken.id}", 0
  end

  test "the nav's Removed is a link now, with its count" do
    get admin_removed_path
    assert_select ".nd-shell__nav a[href=?][aria-current]", admin_removed_path, /Removed\s+3/
  end

  test "a later edit to a record that stays off doesn't replace why it was removed" do
    edited = Directory::FactWriter.write(:organization, { id: @taken.id, description: "Edited while off" },
      verification: { status: "unpublished", by: BY, reason: "Tidied the description" })
    assert edited.ok?, edited.errors.to_sentence
    assert_equal %w[unpublished unpublished], VerificationEvent.where(subject: @taken).order(:id).last.slice(:from_status, :to_status).values,
      "the edit is in the history, as an unpublished-to-unpublished event"

    get admin_removed_path
    assert_select "#row-Organization-#{@taken.id}", /Taken off.*Not nuclear/m
    assert_select "#row-Organization-#{@taken.id}", text: /Tidied the description/, count: 0
  end

  test "a page past the last shows the last page, not an empty one" do
    get admin_removed_path(page: 5)
    assert_select "tbody tr", 3
  end

  test "on phones, Put back and the merged-into link sit above the row's link" do
    css = Rails.root.join("app/assets/tailwind/design_system/components.css").read
    assert_includes css, ".nd-removed td:not(:first-child) a, .nd-removed td form { position: relative; z-index: 1; }"
  end

  test "a record or link opened from Removed leads back to Removed" do
    get admin_removed_path
    record = css_select("#row-Organization-#{@taken.id} td:first-child a").first["href"]
    link = css_select("#row-Relationship-#{@link.id} td:first-child a").first["href"]

    get record
    assert_select ".nd-crumbs a", text: "Removed"
    get link
    assert_select ".nd-crumbs a[href^=?]", "/admin/removed", text: "Removed"
  end
end
