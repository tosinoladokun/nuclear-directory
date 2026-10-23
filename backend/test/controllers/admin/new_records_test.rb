require "test_helper"

# Add a record (#202): a company or plant by hand, from a source and its
# quote. Previewed first; created unpublished; published from its page.
class Admin::NewRecordsTest < ActionDispatch::IntegrationTest
  COMPANY = { kind: "organization", name: "Imaginary Fission Co", website: "https://imaginaryfission.example", role: "reactor_vendor",
    url: "https://example.com/imaginary", quote: "Imaginary Fission Co designs small reactors." }.freeze

  setup do
    sign_in_as users(:admin)
    # As seeded; the site calls it "Reactor designer" (role_label, VOICE.md).
    Role.create!(key: "reactor_vendor", name: "Reactor vendor")
  end

  test "Live's Add a record opens the form" do
    get admin_live_path
    assert_select "a.nd-btn--primary[href^=?]", admin_new_record_path, text: "Add a record"
  end

  test "the preview says what will be created and writes nothing" do
    get admin_new_record_path(COMPANY.merge(preview: 1))

    assert_response :success
    assert_select "#preview-heading", "What will be created"
    assert_select ".nd-panel", /Company: Imaginary Fission Co.*What it does: Reactor designer.*Starts unpublished.*example.com\/imaginary/m
    assert_select "form[action=?] button", admin_new_records_path, text: "Create record"
    assert_nil Organization.find_by(name: "Imaginary Fission Co")
    assert_nil Source.find_by(url: "https://example.com/imaginary"), "nothing kept from a preview"
  end

  test "Create record adds it unpublished, sourced, with what it does, as the admin, and opens its page" do
    post admin_new_records_path, params: COMPANY

    company = Organization.find_by!(name: "Imaginary Fission Co")
    assert_redirected_to admin_record_path(type: "Organization", id: company.id)
    assert_equal "Added Imaginary Fission Co. It isn't published yet.", flash[:notice]
    assert company.pending?
    assert_not Organization.published.exists?(company.id)
    assert_equal [ "Imaginary Fission Co designs small reactors." ], company.evidence.map(&:quote)
    assert_equal %w[reactor_vendor], company.organization_roles.map { |r| r.role.key }
    assert_equal [ "human:tosin", "Added by hand" ], company.verification_events.order(:id).last.slice(:by, :reason).values
  end

  test "a name already in the directory isn't added, and links to that record" do
    existing = organizations(:terrapower)
    get admin_new_record_path(COMPANY.merge(name: existing.name, preview: 1))

    assert_select ".nd-alert", /Not created yet\. Fix this first:.*TerraPower is already in the directory/m
    assert_select ".nd-alert a[href=?]", admin_record_path(type: "Organization", id: existing.id), text: "Open TerraPower"
    assert_select "#preview-heading", 0
  end

  test "a source link and quote, a name and what it does are all required" do
    post admin_new_records_path, params: { kind: "organization" }

    assert_response :unprocessable_content
    assert_select ".nd-alert li", 4
    assert_select ".nd-alert", /Give it a name.*Choose what it does.*Enter a link.*Copy the sentence/m
    assert_equal 0, Organization.where(name: "").count
  end

  test "a plant or site, with its type" do
    post admin_new_records_path, params: { kind: "facility", name: "Imaginary Point", facility_type: "power_reactor",
      url: "https://example.com/point", quote: "Imaginary Point is a power plant." }

    plant = Facility.find_by!(name: "Imaginary Point")
    assert_redirected_to admin_record_path(type: "Facility", id: plant.id)
    assert_equal [ "power_reactor", "pending" ], [ plant.facility_type, plant.verification_status ]
  end

  test "a new name with a company's website isn't added, and leaves that company as it was" do
    existing = organizations(:terrapower)
    post admin_new_records_path, params: COMPANY.merge(name: "TerraPower Holdings", website: "https://www.terrapower.com/about")

    assert_response :unprocessable_content
    assert_select ".nd-alert", /TerraPower already has the website terrapower\.com/
    assert_select ".nd-alert a[href=?]", admin_record_path(type: "Organization", id: existing.id)
    assert_equal [ "TerraPower", "pending" ], existing.reload.slice(:name, :verification_status).values
    assert_empty existing.organization_roles
  end

  test "a duplicate name that's a reactor unit links to its fact page" do
    site = Facility.create!(name: "Imaginary Point")
    unit = Facility.create!(name: "Imaginary Point 1", parent: site)
    get admin_new_record_path(kind: "facility", name: unit.name, url: "https://example.com/p", quote: "q", preview: 1)

    assert_select ".nd-alert a[href=?]", admin_fact_path(type: "Facility", id: unit.id)
  end

  test "Live's filters come back through the preview, the create and the record it opens" do
    back = admin_live_path(tab: "companies", q: "fission")
    get admin_new_record_path(COMPANY.merge(preview: 1, back:))
    assert_select "form[method=get] input[name=back][value=?]", back
    assert_select "form[action=?] input[name=back][value=?]", admin_new_records_path, back
    assert_select ".nd-crumbs a[href=?]", back

    post admin_new_records_path, params: COMPANY.merge(back:)
    assert_redirected_to admin_record_path(type: "Organization", id: Organization.find_by!(name: COMPANY[:name]).id, back:)
  end
end
