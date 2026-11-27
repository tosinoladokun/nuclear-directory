require "test_helper"

# #998: the pass's code-only roles, where a record states the role (Data Quality's rules, 28 Nov).
class DqPass::RecordRolesTest < ActiveSupport::TestCase
  setup { %w[national_lab university].each { |key| Role.find_by(key:) || Role.create!(key:, name: key.humanize) } }

  def pending(name, **attrs) = Organization.create!(name:, verification_status: "pending", **attrs)

  def award(org, quote, kind: "arpa_e_projects")
    source = Source.create!(url: "https://records.example/#{kind}/#{org.id}-#{Source.count}", source_kind: kind)
    Candidate.create!(source:, kind: "organization", status: "matched", quote:, payload: { "name" => org.name }, subject: org)
  end

  def run_step = DqPass::RecordRoles.new.call(CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify"))

  def proposed_role(org) = Candidate.where(kind: "organization_role").find { |claim| claim.payload.dig("organization", "name") == org.name }

  test "a national lab on DOE's list gets national_lab, quoted by its name on DOE's page; by its alias too" do
    sandia = pending("Sandia National Laboratories")
    netl = pending("NETL")
    OrganizationAlias.create!(organization: netl, alias: "National Energy Technology Laboratory")

    assert_equal({ "record_roles" => 2 }, run_step)
    role = proposed_role(sandia)
    assert_equal [ "national_lab", "Sandia National Laboratories", DqPass::RecordRoles::LABS_URL ],
      [ role.payload["role"], role.quote, role.source.url ]
    assert_equal "National Energy Technology Laboratory", proposed_role(netl).quote
    assert_equal 1, DqAction.where(action: "propose_role", candidate: role).count
  end

  test "a university with a .edu site on a nuclear or fusion award gets university, quoted from the award" do
    rutgers = pending("Rutgers University", website: "https://www.rutgers.edu")
    text = "Project: Pioneering a Cermet Waste Form for Disposal of Waste Streams from Advanced Reactors | Organization: Rutgers University"
    award(rutgers, text)

    run_step

    role = proposed_role(rutgers)
    assert_equal [ "university", text ], [ role.payload["role"], role.quote ]
  end

  test "a university on a USAspending row is quoted by the award's description only, never the crawler's label (DQ, #1003)" do
    uni = pending("Example State University", website: "https://www.example.edu")
    row = [ "DENE0009", "EXAMPLE STATE UNIVERSITY", "500000.0", "2025-01-01", "2027-12-31", "assistance", "81.121", "fusion",
      "https://www.usaspending.gov/award/X", "X", "r-1", "MOLTEN SALT REACTOR CORROSION STUDIES", "Department of Energy" ].to_csv.chomp
    award(uni, row, kind: "usaspending_doe_awards")
    batteries = pending("Battery State University", website: "https://battery.example.edu")
    award(batteries, row.sub("MOLTEN SALT REACTOR CORROSION STUDIES", "GRID BATTERY STORAGE").sub("EXAMPLE", "BATTERY"), kind: "usaspending_doe_awards")

    run_step

    assert_equal "MOLTEN SALT REACTOR CORROSION STUDIES", proposed_role(uni).quote
    assert_nil proposed_role(batteries), "the fusion search label alone isn't nuclear work"
  end

  test "a university's smaller nuclear award gives its role, quoted by that award's description (Copilot, #1003)" do
    uni = pending("Mixed State University", website: "https://www.mixed.example.edu")
    columns = DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS
    row = ->(id, text) { [ id, "MIXED STATE UNIVERSITY", "1.0", "2025-01-01", "2027-12-31", "assistance", "81.121", "fusion",
      "https://www.usaspending.gov/award/#{id}", id, "r", text, "Department of Energy" ].to_csv }
    source = Source.create!(url: "https://www.usaspending.gov/recipient/mixed", source_kind: "usaspending_doe_awards",
      content_text: columns.to_csv + row.("A1", "GRID BATTERY STORAGE") + row.("A2", %(FUSION "REACTOR" MATERIALS RESEARCH)))
    Candidate.create!(source:, kind: "organization", status: "matched", quote: row.("A1", "GRID BATTERY STORAGE").chomp,
      payload: { "name" => uni.name }, subject: uni)

    run_step

    role = proposed_role(uni)
    assert_equal %(FUSION "REACTOR" MATERIALS RESEARCH), role.quote
    assert DataQuality::Plugins::UsaspendingDoeAwards.new.quote_in_source?(source, role.quote),
      "the description with its quotes is found in the stored CSV, which writes them doubled"
  end

  test "no role: a university without a .edu site, one on an award with no nuclear work or only LENR, a company's award, a lab not on the list" do
    award(pending("Example University"), "Project: Advanced Reactors")
    award(pending("Stanford University", website: "https://www.stanford.edu"), "Project: Low-energy nuclear reactions (LENR) calorimetry")
    award(pending("Battery University", website: "https://battery.edu"), "Project: Batteries")
    award(pending("Curio Solutions"), "Project: Closing the Cycle with NuCycle, nuclear fuel recycling")
    pending("Acme Research Laboratory")

    assert_equal({ "record_roles" => 0 }, run_step)
    assert_equal 0, Candidate.where(kind: "organization_role").count
  end

  test "a company that has a role, or a role already proposed, is left alone; a second run proposes nothing new" do
    sandia = pending("Sandia National Laboratories")
    run_step
    assert_equal({ "record_roles" => 0 }, run_step)
    assert_equal 1, Candidate.where(kind: "organization_role").count
    assert proposed_role(sandia)
  end
end
