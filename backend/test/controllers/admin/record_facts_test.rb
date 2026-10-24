require "test_helper"

# Add a fact (#202): a role or technology on a company, by hand, from a
# source and its quote. Previewed first; added unpublished, as the admin.
class Admin::RecordFactsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    Role.create!(key: "fuel", name: "Fuel")
    Technology.create!(key: "smr", name: "Small modular reactor")
    @company = Organization.create!(name: "Imaginary Fission", verification_status: "verified", verified_by: "human:tosin")
    @fuel = { kind: "role", key: "fuel", url: "https://example.com/fuel", quote: "Imaginary Fission makes reactor fuel." }
  end

  def path(**extra) = admin_record_new_fact_path(type: "Organization", id: @company.id, **extra)

  test "a company's page has Add a fact" do
    get admin_record_path(type: "Organization", id: @company.id)
    assert_select "a[href^=?]", path, text: "Add a fact"
  end

  test "a removed company has no Add fact: it's put back first" do
    @company.update_columns(verification_status: "unpublished")
    get admin_record_path(type: "Organization", id: @company.id)
    assert_select ".nd-btn", text: /Add (a )?fact/, count: 0
  end

  test "the preview says what will be added and writes nothing" do
    get path(**@fuel, preview: 1)

    assert_select "#preview-heading", "What will be added"
    assert_select ".nd-panel", /Imaginary Fission: what it does: Fuel.*Not public yet.*example.com\/fuel/m
    assert_empty @company.organization_roles
    assert_nil Source.find_by(url: "https://example.com/fuel")
  end

  test "Add fact adds it pending, sourced, as the admin, and goes back to the company" do
    post admin_record_facts_path(type: "Organization", id: @company.id), params: @fuel

    role = @company.organization_roles.sole
    assert_redirected_to admin_record_path(type: "Organization", id: @company.id)
    assert_equal [ "fuel", "pending" ], [ role.role.key, role.verification_status ]
    assert_equal [ "Imaginary Fission makes reactor fuel." ], role.evidence.map(&:quote)
    assert_equal [ "human:tosin", "Added by hand" ], role.verification_events.order(:id).last.slice(:by, :reason).values
  end

  test "a technology too; one already listed, or a missing source, isn't added" do
    post admin_record_facts_path(type: "Organization", id: @company.id),
      params: { kind: "technology", key: "smr", url: "https://example.com/smr", quote: "It designs an SMR." }
    assert_equal %w[smr], @company.organization_technologies.map { |t| t.technology.key }

    post admin_record_facts_path(type: "Organization", id: @company.id),
      params: { kind: "technology", key: "smr", url: "https://example.com/smr", quote: "It designs an SMR." }
    assert_response :unprocessable_content
    assert_select ".nd-alert", /That technology is already listed/

    post admin_record_facts_path(type: "Organization", id: @company.id), params: { kind: "role", key: "fuel" }
    assert_select ".nd-alert", /Enter a link.*Copy the sentence/m
    assert_empty @company.organization_roles
  end

  test "a unit's facts are its site's: no Add a fact on a unit" do
    site = Facility.create!(name: "Imaginary Point")
    unit = Facility.create!(name: "Imaginary Point 1", parent: site)
    get admin_record_new_fact_path(type: "Facility", id: unit.id)
    assert_response :not_found

    get admin_record_path(type: "Facility", id: site.id)
    assert_select "a[href^=?]", admin_record_new_fact_path(type: "Facility", id: site.id), text: "Add a fact"
  end

  test "a removed company takes no new fact, even from an open form" do
    @company.update_columns(verification_status: "unpublished")
    post admin_record_facts_path(type: "Organization", id: @company.id), params: @fuel
    assert_response :not_found
    assert_equal 0, OrganizationRole.count
  end

  SRC = { url: "https://example.com/deal", quote: "The deal was announced." }.freeze

  test "a link to another company: found by name, said as a sentence, Swap reverses it, added pending" do
    meta = Organization.create!(name: "Meta Platforms", verification_status: "verified", verified_by: "human:tosin")
    get path(kind: "company_link", q: "meta")
    assert_select "a[href*=?]", "other=#{meta.id}", text: "Meta Platforms"

    get path(kind: "company_link", other: meta.id, verb: "funds", preview: 1, **SRC)
    assert_select ".nd-panel strong", "Imaginary Fission funds Meta Platforms"
    get path(kind: "company_link", other: meta.id, verb: "funds", swap: "1", preview: 1, **SRC)
    assert_select ".nd-panel strong", "Meta Platforms funds Imaginary Fission"
    assert_equal 0, Relationship.count

    post admin_record_facts_path(type: "Organization", id: @company.id), params: { kind: "company_link", other: meta.id, verb: "funds", swap: "1", **SRC }
    link = Relationship.sole
    assert_equal [ meta.id, @company.id, "funds", "pending" ], [ link.from_organization_id, link.to_organization_id, link.relationship_type, link.verification_status ]

    post admin_record_facts_path(type: "Organization", id: @company.id), params: { kind: "company_link", other: meta.id, verb: "funds", swap: "1", **SRC }
    assert_select ".nd-alert", /That link already exists/
    assert_select ".nd-alert a[href=?]", admin_fact_path(type: "Relationship", id: link.id)
    assert_select ".nd-alert a", text: "Swap", count: 1 # the other direction is still free
  end

  test "a plant's company link: owners may have a share, dates are optional, both checked" do
    site = Facility.create!(name: "Imaginary Point", verification_status: "verified", verified_by: "human:tosin")
    plant = ->(**extra) { admin_record_new_fact_path(type: "Facility", id: site.id, kind: "plant_link", other: @company.id, preview: 1, **SRC, **extra) }

    get plant.(verb: "operates", share: "50")
    assert_select ".nd-alert", /Only an owner has a share/
    get plant.(verb: "owns", share: "150")
    assert_select ".nd-alert", /A share is a number from 0 to 100/
    get plant.(verb: "owns", started_on: "2024-05-01", ended_on: "2020-01-01")
    assert_select ".nd-alert", /It can't end before it starts/

    get plant.(verb: "owns", share: "50", started_on: "2024-05-01")
    assert_select ".nd-panel strong", "Imaginary Fission owns Imaginary Point (50%)"
    assert_select ".nd-panel", /Appears on both pages, from May 1, 2024\./

    post admin_record_facts_path(type: "Facility", id: site.id), params: { kind: "plant_link", other: @company.id, verb: "owns", share: "50", started_on: "2024-05-01", **SRC }
    link = FacilityRelationship.sole
    assert_equal [ 50, Date.new(2024, 5, 1), "pending" ], [ link.ownership_pct.to_i, link.started_on, link.verification_status ]
  end

  test "a unit: a name and an optional docket; a docket already used links to its record" do
    site = Facility.create!(name: "Imaginary Point", verification_status: "verified", verified_by: "human:tosin")
    taken = Facility.create!(name: "Elsewhere 1", nrc_docket: "05000999")
    unit = ->(**extra) { admin_record_new_fact_path(type: "Facility", id: site.id, kind: "unit", preview: 1, **SRC, **extra) }

    get unit.(name: "Imaginary Point 3", docket: "123")
    assert_select ".nd-alert", /An NRC docket is 8 digits/
    get unit.(name: "Imaginary Point 3", docket: "05000999")
    assert_select ".nd-alert", /That unit is already listed/
    assert_select ".nd-alert a[href=?]", admin_record_path(type: "Facility", id: taken.id)

    get unit.(name: "Imaginary Point 3", docket: "05000424")
    assert_select ".nd-panel strong", "Imaginary Point 3 under Imaginary Point, NRC docket 05000424"
    post admin_record_facts_path(type: "Facility", id: site.id), params: { kind: "unit", name: "Imaginary Point 3", docket: "05000424", **SRC }
    added = Facility.find_by!(nrc_docket: "05000424")
    assert_equal [ site.id, "pending" ], [ added.parent_id, added.verification_status ]
  end

  test "a company taken off after the form loaded takes no fact: checked under its lock with the write" do
    @company.update_columns(verification_status: "unpublished")
    added = DataQuality::Review.add_company_fact(organization_id: @company.id, kind: "role", key: "fuel", url: @fuel[:url], quote: @fuel[:quote], by: "human:tosin")
    assert_equal [ "This company was taken off or merged since, so nothing was added" ], added.errors
    assert_empty @company.organization_roles
  end

  test "a link or unit on a record taken off after the form loaded isn't added: checked under its lock with the write" do
    site = Facility.create!(name: "Imaginary Point", verification_status: "verified", verified_by: "human:tosin")
    site.update_columns(verification_status: "unpublished")
    added, = DataQuality::Review.add_link(kind: "plant_link", record_id: site.id, other_id: @company.id, verb: "owns", url: SRC[:url], quote: SRC[:quote], by: "human:tosin")
    assert_equal [ "A record it's on was taken off or merged since, so nothing was added" ], added.errors
    unit = DataQuality::Review.add_unit(site_id: site.id, name: "Imaginary Point 3", url: SRC[:url], quote: SRC[:quote], by: "human:tosin")
    assert_equal [ "A record it's on was taken off or merged since, so nothing was added" ], unit.errors
    assert_equal 0, FacilityRelationship.count
  end

  test "a plant link to a company whose id equals the site's is allowed; the new link's row is the redirect's target" do
    site = Facility.create!(name: "Same Id Point", verification_status: "verified", verified_by: "human:tosin")
    Organization.where(id: site.id).delete_all
    Organization.create!(id: site.id, name: "Same Id Co", verification_status: "verified", verified_by: "human:tosin")
    post admin_record_facts_path(type: "Facility", id: site.id), params: { kind: "plant_link", other: site.id, verb: "operates", **SRC }
    link = FacilityRelationship.find_by!(organization_id: site.id, facility_id: site.id)
    assert_redirected_to admin_record_path(type: "Facility", id: site.id, anchor: "item-FacilityRelationship-#{link.id}")
    follow_redirect!
    assert_select "#item-FacilityRelationship-#{link.id}"
  end

  test "a docket already used by a unit opens that unit's page" do
    site = Facility.create!(name: "Imaginary Point", verification_status: "verified", verified_by: "human:tosin")
    other_site = Facility.create!(name: "Elsewhere")
    unit = Facility.create!(name: "Elsewhere 1", nrc_docket: "05000998", parent: other_site)
    get admin_record_new_fact_path(type: "Facility", id: site.id, kind: "unit", preview: 1, name: "Imaginary Point 3", docket: "05000998", **SRC)
    assert_select ".nd-alert a[href=?]", admin_fact_path(type: "Facility", id: unit.id), text: "Open it"
    get admin_fact_path(type: "Facility", id: unit.id)
    assert_response :success
  end

  test "a link that exists is refused untouched, whatever dates are given; its Open it shows" do
    site = Facility.create!(name: "Dated Point", verification_status: "verified", verified_by: "human:tosin")
    link = FacilityRelationship.create!(organization: @company, facility: site, relationship_type: "operates", started_on: Date.new(2019, 1, 1),
      ended_on: Date.new(2021, 1, 1), verification_status: "verified", verified_by: "human:tosin")
    post admin_record_facts_path(type: "Facility", id: site.id), params: { kind: "plant_link", other: @company.id, verb: "operates", started_on: "2024-01-01", **SRC }
    assert_select ".nd-alert", /That link already exists/
    assert_select ".nd-alert a[href=?]", admin_fact_path(type: "FacilityRelationship", id: link.id), text: "Open it"
    assert_equal [ Date.new(2019, 1, 1), Date.new(2021, 1, 1) ], link.reload.values_at(:started_on, :ended_on)
  end

  test "a unit with its site's own name is added under it" do
    site = Facility.create!(name: "Lonely Point", verification_status: "verified", verified_by: "human:tosin")
    post admin_record_facts_path(type: "Facility", id: site.id), params: { kind: "unit", name: "Lonely Point", docket: "05000777", **SRC }
    unit = Facility.find_by!(nrc_docket: "05000777")
    assert_equal [ site.id, "Lonely Point" ], [ unit.parent_id, unit.name ]
  end

  test "a unit given by another name it goes by, under its site, is the one already listed" do
    site = Facility.create!(name: "Alias Point", verification_status: "verified", verified_by: "human:tosin")
    unit = Facility.create!(name: "Alias Point 1", parent: site)
    unit.aliases.create!(alias: "AP-1")
    get admin_record_new_fact_path(type: "Facility", id: site.id, kind: "unit", preview: 1, name: "AP-1", **SRC)
    assert_select ".nd-alert", /That unit is already listed/
    assert_select ".nd-alert a[href=?]", admin_fact_path(type: "Facility", id: unit.id), text: "Open it"
  end

  test "a record gone before the form is sent says so; a share just over 100 is refused; a source must be https" do
    added, = DataQuality::Review.add_link(kind: "plant_link", record_id: 0, other_id: @company.id, verb: "owns", url: SRC[:url], quote: SRC[:quote], by: "human:tosin")
    assert_includes added.errors, "That record is no longer in the directory"
    unit = DataQuality::Review.add_unit(site_id: 0, name: "Nowhere 1", url: SRC[:url], quote: SRC[:quote], by: "human:tosin")
    assert_includes unit.errors, "That plant is no longer in the directory"
    site = Facility.create!(name: "Share Point", verification_status: "verified", verified_by: "human:tosin")
    added, = DataQuality::Review.add_link(kind: "plant_link", record_id: site.id, other_id: @company.id, verb: "owns", share: "100.00000000000000001",
      url: "http://example.com/x", quote: SRC[:quote], by: "human:tosin")
    assert_includes added.errors, "A share is a number from 0 to 100, with at most two decimal places"
    assert_includes added.errors, "Enter a link to a public source, starting with https://"
  end

  test "a share with more than two decimal places is refused, so the preview is what's stored" do
    site = Facility.create!(name: "Precise Point", verification_status: "verified", verified_by: "human:tosin")
    added, = DataQuality::Review.add_link(kind: "plant_link", record_id: site.id, other_id: @company.id, verb: "owns", share: "99.999",
      url: SRC[:url], quote: SRC[:quote], by: "human:tosin")
    assert_includes added.errors, "A share is a number from 0 to 100, with at most two decimal places"
    added, = DataQuality::Review.add_link(kind: "plant_link", record_id: site.id, other_id: @company.id, verb: "owns", share: "99.99",
      url: SRC[:url], quote: SRC[:quote], by: "human:tosin")
    assert added.ok?, added.errors.inspect
  end
end
