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
    assert_select ".nd-panel", /Imaginary Fission: what it does: Fuel.*Starts unpublished.*example.com\/fuel/m
    assert_empty @company.organization_roles
    assert_nil Source.find_by(url: "https://example.com/fuel")
  end

  test "Add fact adds it pending, sourced, as the admin, and goes back to the company" do
    post admin_record_facts_path(type: "Organization", id: @company.id), params: @fuel

    assert_redirected_to admin_record_path(type: "Organization", id: @company.id)
    role = @company.organization_roles.sole
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

  test "a plant's facts aren't added here yet" do
    plant = Facility.create!(name: "Imaginary Point")
    get admin_record_new_fact_path(type: "Facility", id: plant.id)
    assert_response :not_found
  end
end
