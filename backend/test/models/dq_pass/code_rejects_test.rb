require "test_helper"

# #998: the pass's code-only reject recommendations, by Data Quality's rules (28 Nov).
class DqPass::CodeRejectsTest < ActiveSupport::TestCase
  def pending(name, **attrs) = Organization.create!(name:, verification_status: "pending", **attrs)

  def claim(org, kind, quote, payload: {}, status: "matched")
    source = Source.find_or_create_by!(url: "https://records.example/#{kind}/#{org.id}-#{Candidate.count}") { |made| made.source_kind = kind }
    Candidate.create!(source:, kind: "organization", status:, quote:, payload: { "name" => org.name }.merge(payload), subject: org)
  end

  def run_step = DqPass::CodeRejects.new.call(CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify"))

  def rejected?(claim) = claim.reload.dq_recommendation == "reject"

  test "an award recipient whose awards name no nuclear work is recommended for reject; LENR isn't nuclear work" do
    steel = claim(pending("Limelight Steel"), "arpa_e_projects", "Project: Laser-based ironmaking | Organization: Limelight Steel")
    lenr = claim(pending("Amphionic"), "arpa_e_projects", "Project: Calorimetry of low-energy nuclear reactions (LENR) | Organization: Amphionic")
    fusion = claim(pending("ExoFusion"), "arpa_e_projects", "Project: Novel Liquid Metal Plasma Facing Component Alloys for fusion | Organization: ExoFusion")

    assert_equal({ "code_rejects" => 2 }, run_step)
    assert rejected?(steel)
    assert_match "Server pass (code): its award records name no nuclear work", steel.dq_reason
    assert_equal DataQuality::Matching::BY, steel.dq_by
    assert rejected?(lenr)
    assert_not rejected?(fusion)
  end

  # A USAspending award row as the plugin stores it (its search column is the crawler's own label).
  def usaspending_row(recipient, description)
    [ "DEAR0001910", recipient, "2910346.0", "2024-07-12", "2027-07-11", "assistance", "81.135", "fusion",
      "https://www.usaspending.gov/award/ASST_NON_DEAR0001910_089", "ASST_NON_DEAR0001910_089", "9fbce0fa-R", description,
      "Department of Energy" ].to_csv.chomp
  end

  test "a USAspending row is judged by its description, not the crawler's search label (fusion is a word) (DQ, #1003)" do
    steel = pending("Limelight Steel")
    claim(steel, "usaspending_doe_awards", usaspending_row("LIMELIGHT STEEL INC.", "REVOLUTIONIZING ORE TO STEEL TO IMPACT EMISSIONS (ROSIE) SBIR/STTR"))
    recipient = claim(steel, "usaspending_recipients", "Recipient: LIMELIGHT STEEL INC.\nCity: OAKLAND\nState: CA")
    reactor = claim(pending("Fission Parts"), "usaspending_doe_awards", usaspending_row("FISSION PARTS INC.", "ADVANCED REACTOR FUEL CLADDING"))

    run_step

    assert rejected?(recipient)
    assert_not rejected?(reactor)
  end

  test "a company with only recipient rows, or an unreadable award row, has no award text read: never rejected for it (DQ, #1003)" do
    only = claim(pending("Recipient Only Co"), "usaspending_recipients", "Recipient: RECIPIENT ONLY CO\nCity: RENO\nState: NV")
    broken = claim(pending("Broken Row Co"), "usaspending_doe_awards", "not, a \"valid row")

    run_step

    assert_not rejected?(only)
    assert_not rejected?(broken)
  end

  # A recipient's stored USAspending source: every award row, as the plugin writes it.
  def usaspending_source(org, *descriptions)
    header = DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS.to_csv
    rows = descriptions.each_with_index.map { |text, i| usaspending_row(org.name.upcase, text).sub("DEAR0001910", "DEAR000#{i}") + "\n" }
    Source.create!(url: "https://www.usaspending.gov/recipient/#{org.id}", source_kind: "usaspending_doe_awards", content_text: header + rows.join)
  end

  test "every award of a USAspending recipient counts, not only the largest one its claim quotes (Copilot, #1003)" do
    org = pending("Mixed Awards Co")
    source = usaspending_source(org, "GRID BATTERY STORAGE DEMONSTRATION", "ADVANCED REACTOR FUEL CLADDING")
    mixed = Candidate.create!(source:, kind: "organization", status: "matched", payload: { "name" => org.name }, subject: org,
      quote: usaspending_row(org.name.upcase, "GRID BATTERY STORAGE DEMONSTRATION"))
    other = pending("Battery Only Co")
    battery = Candidate.create!(source: usaspending_source(other, "GRID BATTERY STORAGE", "SOLAR INVERTERS"), kind: "organization",
      status: "matched", payload: { "name" => other.name }, subject: other, quote: usaspending_row(other.name.upcase, "GRID BATTERY STORAGE"))

    run_step

    assert_not rejected?(mixed), "a smaller award names nuclear work"
    assert rejected?(battery)
  end

  test "an ML accession with a letter is a document's title on its own (Copilot, #1003)" do
    accession = claim(pending("ML24123A456"), "nrc_adams", "ML24123A456")
    run_step
    assert rejected?(accession)
  end

  test "only an owns or operates link keeps a utility; an offtake or vendor link doesn't (Copilot, #1003)" do
    plant = Facility.create!(name: "Example Station", verification_status: "verified", verified_by: "human:test")
    offtaker = pending("Offtake Power Co", eia_utility_id: "88881")
    FacilityRelationship.create!(organization: offtaker, facility: plant, relationship_type: "offtakes_from")
    owner = pending("Owner Power Co", eia_utility_id: "88882")
    FacilityRelationship.create!(organization: owner, facility: plant, relationship_type: "owns")
    off = claim(offtaker, "usaspending_recipients", "Recipient: OFFTAKE POWER CO")
    own = claim(owner, "usaspending_recipients", "Recipient: OWNER POWER CO")

    run_step

    assert rejected?(off)
    assert_not rejected?(own)
  end

  test "a document's title, a utility with no nuclear plant, and a foreign record with no US address" do
    doc = claim(pending("Westinghouse Summary Report ML24123A456"), "nrc_adams", "Summary Report")
    utility = claim(pending("Plains Power Co", eia_utility_id: "99999"), "usaspending_recipients", "Recipient: Plains Power Co, nuclear fuel study")
    foreign = claim(pending("Nordic Fission AB"), "lead_finder", "Nordic Fission builds reactors", payload: { "country_code" => "SE" })
    us = claim(pending("Texas Fission"), "lead_finder", "Texas Fission builds reactors", payload: { "country_code" => "SE", "hq_state" => "TX" })

    run_step

    assert rejected?(doc)
    assert rejected?(utility)
    assert_match "in SE, with no US address", foreign.reload.dq_reason
    assert_not rejected?(us), "a US state in a record keeps it"
  end

  test "never a university, lab, government body or investor, a company a person suggested, or one already decided" do
    uni = claim(pending("Example University"), "arpa_e_projects", "Project: Batteries | Organization: Example University")
    fund = claim(pending("Atom Capital"), "usaspending_recipients", "Recipient: Atom Capital")
    org = pending("Suggested Steel")
    Lead.sighted!(name: "Suggested Steel", kind: "company", key: "admin:suggest:suggested steel", label: "Added in the admin")
    suggested = claim(org, "arpa_e_projects", "Project: Steel | Organization: Suggested Steel")
    approved = claim(pending("Done Steel"), "arpa_e_projects", "Project: Steel", status: "confirmed")
    published = claim(Organization.create!(name: "Verified Steel", verification_status: "verified", verified_by: "human:tosin"), "arpa_e_projects", "Project: Steel")

    assert_equal({ "code_rejects" => 0 }, run_step)
    [ uni, fund, suggested, approved, published ].each { |made| assert_not rejected?(made), made.payload["name"] }
  end

  test "a claim it already recommended isn't sent again, and a second run records nothing new" do
    steel = claim(pending("Limelight Steel"), "arpa_e_projects", "Project: Laser-based ironmaking")
    run_step
    assert rejected?(steel)
    assert_equal({ "code_rejects" => 0 }, run_step)
    assert_equal 1, DqAction.where(candidate: steel, action: "recommend").count
  end
end
