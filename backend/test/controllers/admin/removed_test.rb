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
end
