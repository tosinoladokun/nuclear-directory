require "test_helper"

# Merge into… on a Record (#142): pick the record it's the same as, see what
# would move, give a reason, then the same audited merge as the rake tasks.
class Admin::MergeTest < ActionDispatch::IntegrationTest
  VERIFIED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  setup do
    @web = Source.create!(url: "https://www.example.com/merge", source_kind: "web_page", domain: "example.com")
    sign_in_as users(:admin)
  end

  def sourced(fact) = fact.tap { Evidence.create!(subject: fact, source: @web, quote: fact.name, found_by: "human") }

  test "a company: find the one kept by another name, see what moves, then merge with a reason" do
    kept = sourced(Organization.create!(name: "BWXT", **VERIFIED))
    kept.aliases.create!(alias: "BWX Technologies")
    duplicate = sourced(Organization.create!(name: "BWXT Nuclear Energy"))
    duplicate.aliases.create!(alias: "BWXT NUCLEAR ENERGY, INC.")
    page = ->(**params) { admin_record_merge_path(type: "Organization", id: duplicate.id, **params) }

    get admin_record_path(type: "Organization", id: duplicate.id)
    assert_select "a[href=?]", page.(), "Merge into…"

    get page.(q: "BWX Tech")
    assert_select "a[href=?]", page.(into: kept.id), "BWXT"
    assert_select ".nd-panel a", { text: "BWXT Nuclear Energy", count: 0 }, "not itself"

    get page.(into: kept.id)
    assert_select "p", /Moves to BWXT: 1 other name, 1 source quote\./
    assert_select "p", /Only merge if they're the same company/
    assert duplicate.reload.pending?, "seeing what moves changes nothing"

    post page.(), params: { into: kept.id, reason: "" }
    assert_response :unprocessable_content
    assert_select ".nd-alert", /say why they're the same/
    assert duplicate.reload.pending?

    post page.(), params: { into: kept.id, reason: "BWXT's nuclear energy unit (DOE award)" }
    assert_response :see_other
    assert_redirected_to admin_record_path(type: "Organization", id: kept.id)
    assert_equal "Merged into BWXT.", flash[:notice]
    assert duplicate.reload.unpublished?
    assert_match "BWXT's nuclear energy unit", duplicate.verification_events.order(:id).last.reason
    assert_equal({ "type" => "Organization", "id" => kept.id }, duplicate.verification_events.order(:id).last.context["merged_into"])
    assert_includes kept.former_slugs.pluck(:slug), duplicate.slug, "its address leads to the one kept"
    assert_equal kept.id, Directory::Lookup.organization(name: "BWXT NUCLEAR ENERGY, INC.")&.id
    assert_equal kept.id, Directory::Lookup.organization(name: "BWXT Nuclear Energy")&.id, "its own name is an alias of the one kept now"
  end

  test "a plant site merges into another site, found by a unit's docket" do
    kept = sourced(Facility.create!(name: "Plant Vogtle", **VERIFIED))
    Facility.create!(name: "Vogtle 1", parent: kept, nrc_docket: "05000424", **VERIFIED)
    duplicate = sourced(Facility.create!(name: "Vogtle"))

    get admin_record_merge_path(type: "Facility", id: duplicate.id, q: "05000424")
    assert_select "a", "Plant Vogtle"

    post admin_record_merge_path(type: "Facility", id: duplicate.id), params: { into: kept.id, reason: "Same plant" }
    assert_redirected_to admin_record_path(type: "Facility", id: kept.id)
    assert duplicate.reload.unpublished?
  end

  test "a plant merge that only fills the kept site's blank fields says so, not that nothing moves" do
    kept = sourced(Facility.create!(name: "Kept Plant", **VERIFIED))
    duplicate = Facility.create!(name: "Duplicate Plant", status: "operating", eia_plant_id: "6051")

    get admin_record_merge_path(type: "Facility", id: duplicate.id, into: kept.id)

    assert_select "p", /Moves to Kept Plant: 1 other name, fills in Kept Plant's EIA plant ID and status\./
    assert_select "p", text: /Nothing else moves/, count: 0
  end

  test "when nothing moves, it says so rather than naming a field" do
    kept = sourced(Organization.create!(name: "Kept Co", **VERIFIED))
    twin = Organization.create!(name: "KEPT CO") # the same name: not even an alias moves

    get admin_record_merge_path(type: "Organization", id: twin.id, into: kept.id)

    assert_select "p", /\ANothing else moves\. KEPT CO is then taken off/
  end

  test "merging into a company not approved yet warns that neither page is public until it is" do
    live = sourced(Organization.create!(name: "Live Brand Co", **VERIFIED))
    pending = Organization.create!(name: "Pending Brand Co")

    get admin_record_merge_path(type: "Organization", id: live.id, into: pending.id)

    assert_select "p", /Pending Brand Co isn't on the public site yet,\s+so neither page is public until it is/
  end

  test "a pending site that's public through a live unit gets no warning" do
    duplicate = sourced(Facility.create!(name: "Old Name Plant", **VERIFIED))
    site = Facility.create!(name: "Half Live Plant")
    sourced(Facility.create!(name: "Half Live 1", parent: site, **VERIFIED))
    assert Facility.published.exists?(site.id)

    get admin_record_merge_path(type: "Facility", id: duplicate.id, into: site.id)

    assert_select "p", text: /isn't on the public site yet/, count: 0
  end

  test "claims moved by a merge didn't propose the record kept, so rejecting one later never retires it" do
    kept = sourced(Organization.create!(name: "Kept Brand", **VERIFIED))
    duplicate = Organization.create!(name: "Kept Brand Holdings")
    claim = Candidate.create!(source: @web, kind: "organization", quote: "q", status: "needs_review", payload: { "name" => "Kept Brand Holdings" },
      subject_type: "Organization", subject_id: duplicate.id, proposed_subject: true)

    post admin_record_merge_path(type: "Organization", id: duplicate.id), params: { into: kept.id, reason: "Same company" }

    assert_equal [ kept.id, false ], [ claim.reload.subject_id, claim.proposed_subject ]
  end

  test "a removed record isn't merged from here, nor merged into" do
    gone = sourced(Organization.create!(name: "Gone Co", **VERIFIED))
    gone.unpublish!(by: "human:tosin", reason: "Test")
    live = sourced(Organization.create!(name: "Live Co", **VERIFIED))

    get admin_record_merge_path(type: "Organization", id: gone.id)
    assert_redirected_to admin_record_path(type: "Organization", id: gone.id)
    assert_match "Put it back first", flash[:alert]

    get admin_record_merge_path(type: "Organization", id: live.id, q: "Gone")
    assert_select "p", /No company matches/
    post admin_record_merge_path(type: "Organization", id: live.id), params: { into: gone.id, reason: "x" }
    assert_redirected_to admin_record_merge_path(type: "Organization", id: live.id)
    assert live.reload.verified?
  end

  test "a Record with no facts has no empty field list" do
    bare = Organization.create!(name: "Bare Co")

    get admin_record_path(type: "Organization", id: bare.id)

    assert_select ".nd-factcard dl.nd-kv", 0
  end
end
