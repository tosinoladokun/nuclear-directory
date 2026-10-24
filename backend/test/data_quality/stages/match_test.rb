require "test_helper"
require_relative "../support/dummy_plugin"

# Match against the real directory with NRC-style names, since what matters
# is how real names and dockets resolve.
class DataQuality::Stages::MatchTest < ActiveSupport::TestCase
  include ReviewHelpers

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/match-stage-sample.html",
      source_kind: "dummy", crawl_status: "ok")
  end

  def candidate(kind, payload, quote: "row from the NRC list")
    Candidate.create!(source: @source, kind: kind, payload: payload, quote: quote)
  end

  def match! = DataQuality::Stages::Match.call(plugin: DummyPlugin.new)

  def facility_payload(name, docket) = { "name" => name, "nrc_docket" => docket, "facility_type" => "power_reactor" }

  # The seed's Vogtle record, in place of the fixture's (two Vogtle sites would be ambiguous).
  def vogtle_site!
    facilities(:vogtle).destroy!
    Facility.create!(name: "Plant Vogtle Units 3 & 4")
  end

  test "a facility matched by NRC docket is attached; its quote is added only on approval" do
    site = Facility.create!(name: "Braidwood Station", nrc_docket: "05000456")
    c = candidate("facility", facility_payload("Braidwood 1", "05000456"), quote: "Braidwood 1 05000456")

    run = match!

    c.reload
    assert c.status_matched?
    assert_equal [ "Facility", site.id ], [ c.subject_type, c.subject_id ]
    assert_match "by NRC docket", c.notes
    assert_equal "Braidwood Station", site.reload.name, "matching doesn't overwrite the record"
    assert_empty site.evidence, "nothing is written to an existing record before verification"
    assert_equal 1, run.stats["matched"]

    verify = DataQuality::Stages::Verify.call(plugin: DummyPlugin.new, verifier: PublishEverything.new)
    assert_empty site.reload.evidence, "verify only recommends"
    approve_recommended
    evidence = site.evidence.sole
    assert_equal [ "crawler", "Braidwood 1 05000456", verify.id ], [ evidence.found_by, evidence.quote, evidence.crawl_run_id ]
  end

  test "a facility found by one of its other names is attached, writing nothing" do
    site = Facility.create!(name: "Peach Bottom Atomic Power Station")
    site.aliases.create!(alias: "PBAPS")
    c = candidate("facility", { "name" => "Peach Bottom Plant", "aliases" => [ "PBAPS", "Peach Bottom 2 and 3" ],
      "facility_type" => "power_reactor" })

    match!

    assert_equal [ "Facility", site.id ], [ c.reload.subject_type, c.subject_id ]
    assert c.status_matched?
    assert_equal [ "PBAPS" ], site.aliases.pluck(:alias), "aliases wait for approval"
    assert_empty site.evidence
  end

  test "an unknown facility is proposed as a new pending record" do
    c = candidate("facility", facility_payload("Arkansas Nuclear 1", "05000313"))

    run = match!

    facility = Facility.find(c.reload.subject_id)
    assert c.status_matched?
    assert_equal [ "Arkansas Nuclear 1", "05000313" ], [ facility.name, facility.nrc_docket ]
    assert facility.pending?
    assert_match "proposed a new pending one", c.notes
    assert_equal 1, run.stats["proposed"]
  end

  test "units with different dockets aren't mistaken for duplicates" do
    first = candidate("facility", facility_payload("Braidwood 1", "05000456"))
    second = candidate("facility", facility_payload("Braidwood 2", "05000457"))

    match!

    assert [ first, second ].all? { |c| c.reload.status_matched? }
    assert_not_equal first.subject_id, second.subject_id
  end

  test "an NRC unit is added under the seed site it clearly belongs to" do
    site = vogtle_site!
    c = candidate("facility", facility_payload("Vogtle 3", "05200025"))

    run = match!

    unit = Facility.find(c.reload.subject_id)
    assert c.status_matched?
    assert_equal [ "Vogtle 3", "05200025", site.id ], [ unit.name, unit.nrc_docket, unit.parent_id ]
    assert unit.pending?
    assert_match "under the existing site Plant Vogtle Units 3 & 4", c.notes
    assert_equal 1, run.stats["proposed"]
  end

  test "a site whose name lists no units takes any of its units" do
    site = Facility.create!(name: "Clinton Clean Energy Center")
    single = candidate("facility", facility_payload("Clinton", "05000461"))
    lasalle = Facility.create!(name: "La Salle County Station")
    numbered = candidate("facility", facility_payload("LaSalle 1", "05000373"))

    match!

    assert_equal site.id, Facility.find(single.reload.subject_id).parent_id
    assert_equal lasalle.id, Facility.find(numbered.reload.subject_id).parent_id, "spacing differences still match"
  end

  test "a unit is never placed under a rejected site" do
    vogtle_site!.reject!(by: "human:tosin")
    c = candidate("facility", facility_payload("Vogtle 3", "05200025"))

    assert_no_difference "Facility.count" do
      match!
    end

    assert c.reload.status_needs_review?
    assert_match "which was rejected", c.notes
  end

  test "a unit the site record doesn't cover goes to review, never merged" do
    vogtle_site!
    Facility.create!(name: "Palisades Pioneer Units 1 & 2 (SMR-300)")
    older = candidate("facility", facility_payload("Vogtle 1", "05000424"))
    unnumbered = candidate("facility", facility_payload("Palisades", "05000255"))

    assert_no_difference "Facility.count" do
      match!
    end

    assert older.reload.status_needs_review?
    assert_match "only covers unit 3 & 4", older.notes
    assert unnumbered.reload.status_needs_review?
    assert_match "only covers unit 1 & 2", unnumbered.notes
  end

  test "sibling units all go under the same site" do
    site = vogtle_site!
    units = [ facility_payload("Vogtle 3", "05200025"), facility_payload("Vogtle 4", "05200026") ]
      .map { |payload| candidate("facility", payload) }

    match!

    assert_equal [ site.id, site.id ], units.map { |c| Facility.find(c.reload.subject_id).parent_id }
  end

  test "more than one possible site goes to review" do
    Facility.create!(name: "Susquehanna Steam Electric Station")
    Facility.create!(name: "Susquehanna Riverlands")
    c = candidate("facility", facility_payload("Susquehanna 1", "05000387"))

    match!

    assert c.reload.status_needs_review?
    assert_match "Susquehanna Steam Electric Station; Susquehanna Riverlands", c.notes
  end

  test "a facility without a docket isn't treated as a unit" do
    c = candidate("facility", { "name" => "Vogtle Visitor Center" })

    match!

    assert c.reload.status_needs_review?
    assert_match "Vogtle Electric Generating Plant", c.notes
  end

  test "docket and name pointing at different facilities goes to review" do
    Facility.create!(name: "Unit A", nrc_docket: "05000001")
    Facility.create!(name: "Unit B", nrc_docket: "05000002")
    c = candidate("facility", facility_payload("Unit B", "05000001"))

    match!

    assert c.reload.status_needs_review?
    assert_match "docket matches Unit A but name matches Unit B", c.notes
  end

  test "an organization matched by name keeps its record and status" do
    terrapower = organizations(:terrapower)
    terrapower.verify!(by: "human:tosin")
    c = candidate("organization", { "name" => "TerraPower, Inc." })

    match!

    # A name it already has (normalized) only adds evidence, so it confirms itself (#548).
    assert c.reload.status_confirmed?, c.notes
    assert_equal terrapower.id, c.subject_id
    terrapower.reload
    assert terrapower.verified?
    assert_equal "human:tosin", terrapower.verified_by
    assert_equal "TerraPower", terrapower.name
  end

  test "a company is found by another spelling it came under, as a plant is (#302)" do
    organizations(:terrapower).aliases.create!(alias: "TERRAPOWER ISOTOPES DIVISION")
    c = candidate("organization", { "name" => "Terrapower Holdings", "aliases" => [ "TERRAPOWER ISOTOPES DIVISION" ] })

    match!

    assert_equal organizations(:terrapower).id, c.reload.subject_id
    assert_match "by name", c.notes
  end

  test "the name a match was found under becomes an alias only once it's approved" do
    c = candidate("organization", { "name" => "TP Nuclear Holdings", "domain" => "terrapower.com" })

    match!

    assert_equal organizations(:terrapower).id, c.reload.subject_id
    assert_match "by domain", c.notes
    assert_nil Directory::Lookup.organization(name: "TP Nuclear Holdings"), "not yet: the match might be rejected"

    DataQuality::Stages::Verify.call(plugin: DummyPlugin.new, verifier: PublishEverything.new)
    approve_recommended
    assert_equal organizations(:terrapower).id, Directory::Lookup.organization(name: "TP Nuclear Holdings").id
  end

  test "an unpublished record is a human decision: never attached to, and the note says who and when" do
    organizations(:terrapower).unpublish!(by: "human:tosin")
    c = candidate("organization", { "name" => "TerraPower, Inc." })

    match!

    assert c.reload.status_needs_review?
    assert_match(/which was unpublished by human:tosin on \d{4}-\d{2}-\d{2}/, c.notes)
  end

  test "a record that was rejected is never attached to" do
    rejected = Directory::FactWriter.write(:organization, { name: "Imaginary Fission Co" }).id
    Organization.find(rejected).reject!(by: "agent:verifier/x")
    c = candidate("organization", { "name" => "Imaginary Fission Co" })

    match!

    assert c.reload.status_needs_review?
    assert_match "which was rejected", c.notes
  end

  test "name and domain pointing at different organizations goes to review" do
    c = candidate("organization", { "name" => "TerraPower", "domain" => "westinghousenuclear.com" })

    match!

    assert c.reload.status_needs_review?
    assert_match "name matches TerraPower but domain matches Westinghouse", c.notes
  end

  test "a similar company with a different brand goes to review" do
    Directory::FactWriter.write(:organization, { name: "Southern Company" })
    c = candidate("organization", { "name" => "Southern California Edison" })

    assert_no_difference "Organization.count" do
      match!
    end

    assert c.reload.status_needs_review?
    assert_match "Southern Company", c.notes
  end

  test "one company per brand: a legal-entity variant is that company" do
    constellation = Directory::FactWriter.write(:organization, { name: "Constellation Energy Corporation" }).id
    dominion = Directory::FactWriter.write(:organization, { name: "Dominion Energy" }).id
    generation = candidate("organization", { "name" => "Constellation Energy Generation, LLC" })
    arm = candidate("organization", { "name" => "Dominion Generation" })

    assert_no_difference "Organization.count" do
      match!
    end

    assert_equal [ constellation, dominion ], [ generation, arm ].map { |c| c.reload.subject_id }
    assert_match "by brand", generation.notes

    DataQuality::Review.approve([ arm.id ], by: "human:tosin")
    assert_equal dominion, Directory::Lookup.organization(name: "Dominion Generation").id,
      "once published, the variant is an alias, so the next run matches it exactly"
  end

  test "Southern Nuclear is its own company, not Southern Company" do
    Directory::FactWriter.write(:organization, { name: "Southern Company" })
    c = candidate("organization", { "name" => "Southern Nuclear Operating Co., Inc." })

    match!

    assert c.reload.status_needs_review?, "similar to Southern Company, so a human decides; never merged into it"
    assert_nil c.subject_id
  end

  test "a per-plant LLC belongs to its brand, which a new company is named after" do
    Facility.create!(name: "Point Beach 1", nrc_docket: "05000266")
    Facility.create!(name: "Seabrook 1", nrc_docket: "05000443")
    point_beach = candidate("organization", { "name" => "NextEra Energy Point Beach, LLC" })
    seabrook = candidate("organization", { "name" => "NextEra Energy Seabrook, LLC" })

    assert_difference "Organization.count", 1 do
      match!
    end

    nextera = Organization.find(point_beach.reload.subject_id)
    assert_equal "NextEra Energy", nextera.name
    assert_equal nextera.id, seabrook.reload.subject_id
    assert_equal nextera.id, Directory::Lookup.organization(name: "NextEra Energy Point Beach, LLC").id, "legal name kept as an alias"
  end

  test "a regional operating company belongs to its brand" do
    duke = Directory::FactWriter.write(:organization, { name: "Duke Energy" }).id
    holtec = Directory::FactWriter.write(:organization, { name: "Holtec International" }).id
    Facility.create!(name: "Palisades", nrc_docket: "05000255")
    carolinas = candidate("organization", { "name" => "Duke Energy Carolinas, LLC" })
    palisades = candidate("organization", { "name" => "Holtec Palisades, LLC" })

    match!

    assert_equal [ duke, holtec ], [ carolinas, palisades ].map { |c| c.reload.subject_id }
  end

  test "a brand match that disagrees with the domain goes to review" do
    Directory::FactWriter.write(:organization, { name: "Dominion Energy" })
    c = candidate("organization", { "name" => "Dominion Generation", "domain" => "terrapower.com" })

    match!

    assert c.reload.status_needs_review?
    assert_match "brand of Dominion Energy but domain matches TerraPower", c.notes
  end

  test "a per-plant name whose brand isn't in the directory yet must agree with the domain" do
    Facility.create!(name: "Seabrook Station")
    c = candidate("organization", { "name" => "NextEra Energy Seabrook, LLC", "domain" => "terrapower.com" })

    match!

    assert c.reload.status_needs_review?
    assert_match "name is a NextEra Energy company but domain matches TerraPower", c.notes
  end

  test "a brand shared by two companies goes to review" do
    Directory::FactWriter.write(:organization, { name: "Urenco" })
    Directory::FactWriter.write(:organization, { name: "Urenco USA" })
    c = candidate("organization", { "name" => "Urenco Nuclear Operations LLC" })

    match!

    assert c.reload.status_needs_review?
    assert_match "could be the same brand as Urenco or Urenco USA", c.notes
  end

  test "a shared brand goes to review even when the domain matches one of them" do
    Directory::FactWriter.write(:organization, { name: "Urenco", website: "https://urenco.com" })
    Directory::FactWriter.write(:organization, { name: "Urenco USA" })
    c = candidate("organization", { "name" => "Urenco Nuclear Operations LLC", "website" => "https://urenco.com/usa" })

    match!

    assert c.reload.status_needs_review?
    assert_match "could be the same brand as Urenco or Urenco USA (its domain matches Urenco)", c.notes
  end

  test "a shared brand's note lists the companies in name order, whatever order the lookup returns" do
    Directory::FactWriter.write(:organization, { name: "Urenco" })
    Directory::FactWriter.write(:organization, { name: "Urenco USA" })
    directory = DataQuality::DirectoryClient.new
    # Descending on purpose: the opposite of the order the note must show.
    directory.define_singleton_method(:same_brand_organizations) { |name| super(name).sort_by(&:name).reverse }
    c = candidate("organization", { "name" => "Urenco Nuclear Operations LLC" })

    DataQuality::Stages::Match.call(plugin: DummyPlugin.new, directory:)

    assert_match "could be the same brand as Urenco or Urenco USA", c.reload.notes
  end

  test "brand checks read the plant names once per run, and again after a facility is written" do
    lookup = SimpleDelegator.new(Directory::Lookup)
    reads = 0
    lookup.define_singleton_method(:plant_names) { |owners: []| reads += 1; __getobj__.plant_names(owners:) }
    client = DataQuality::DirectoryClient.new(lookup:)

    client.same_brand_organizations("NextEra Energy Seabrook, LLC")
    client.brand_name("NextEra Energy Seabrook, LLC")
    assert_equal 1, reads
    client.write_pending("facility", { name: "Seabrook Station" }, candidate: candidate("facility", {}),
      crawl_run: Struct.new(:id).new(nil))
    assert_equal "NextEra Energy", client.brand_name("NextEra Energy Seabrook, LLC"), "Seabrook is now a known plant"
    assert_equal 2, reads
    client.write_pending("organization", { name: "Seabrook Holdings" }, candidate: candidate("organization", {}),
      crawl_run: Struct.new(:id).new(nil))
    client.brand_name("NextEra Energy Seabrook, LLC")
    assert_equal 3, reads, "company names change which short forms count as plants"
  end

  test "a company proposed in the same run counts as an owner, whatever the order" do
    candidate("organization", { "name" => "Acme Urenco Eunice, LLC" })
    candidate("organization", { "name" => "Urenco Eunice" })
    candidate("facility", { "name" => "Urenco Eunice Enrichment Plant", "facility_type" => "enrichment" })

    match!

    assert Organization.exists?(name: "Acme Urenco Eunice, LLC"),
      "Urenco Eunice is a company in this run, so it is the plant's owner, not a plant name to strip"
  end

  test "a plant proposed in the same run is known when companies are matched" do
    candidate("organization", { "name" => "Acme Power Fernhill, LLC" })
    candidate("facility", { "name" => "Fernhill Generating Station", "facility_type" => "power_reactor" })

    match!

    assert Organization.exists?(name: "Acme Power"), "proposed under its brand, since Fernhill is a plant"
  end

  test "an organization listed on many rows is proposed once; the repeat closes while the first waits" do
    rows = 2.times.map { candidate("organization", { "name" => "Entergy Nuclear Operations, Inc." }) }

    run = match!

    assert_equal 1, Organization.where(name: "Entergy Nuclear Operations, Inc.").count
    assert_equal rows.map { |c| c.reload.subject_id }.uniq.size, 1
    assert_equal [ 1, 0, 1 ], run.stats.values_at("proposed", "matched", "confirmed")
    assert_match "Same as candidate ##{rows.first.id}, already waiting", rows.last.reload.notes, "one waits for review; the repeat closes (#240)"
  end

  test "a new link and its quote are written together, or not at all" do
    # The quote write fails after the link was created: nothing may be left behind.
    directory = DataQuality::DirectoryClient.new
    directory.define_singleton_method(:write_pending) do |kind, attributes, **options|
      return DataQuality::DirectoryClient::WriteResult.new(ref: nil, errors: [ "disk full" ]) if attributes.keys == [ :id ]

      super(kind, attributes, **options)
    end
    link = candidate("facility_relationship", {
      "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => "Vogtle Electric Generating Plant" },
      "relationship_type" => "operates"
    })

    DataQuality::Stages::Match.call(plugin: DummyPlugin.new, directory:)

    assert link.reload.status_needs_review?
    assert_match "disk full", link.notes
    assert_not FacilityRelationship.exists?(relationship_type: "operates"), "the link was rolled back"
  end

  test "an operates link finds records proposed earlier in the same run" do
    candidate("organization", { "name" => "Entergy Nuclear Operations, Inc." })
    candidate("facility", facility_payload("Arkansas Nuclear 1", "05000313"))
    link = candidate("facility_relationship", {
      "organization" => { "name" => "Entergy Nuclear Operations, Inc." },
      "facility" => { "name" => "Arkansas Nuclear 1", "nrc_docket" => "05000313" },
      "relationship_type" => "operates"
    })

    run = match!

    link.reload
    assert link.status_matched?, link.notes
    record = FacilityRelationship.find(link.subject_id)
    assert record.operates?
    assert record.pending?
    assert_equal "Arkansas Nuclear 1", record.facility.name
    assert_equal [ link.quote ], record.evidence.pluck(:quote), "a new link is a proposal and carries its quote"
    assert_equal 3, run.stats["proposed"]
  end

  test "matching an existing link leaves its curated attributes and verification alone" do
    link = FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle),
      relationship_type: "owns", description: "Curated description", ownership_pct: 40)
    link.verify!(by: "human:tosin")
    c = candidate("facility_relationship", {
      "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => "Vogtle Electric Generating Plant" },
      "relationship_type" => "owns",
      "description" => "Candidate description",
      "ownership_pct" => 75
    })

    match!

    assert c.reload.status_matched?
    assert_equal link.id, c.subject_id
    link.reload
    assert_equal [ "Curated description", 40 ], link.slice(:description, :ownership_pct).values
    assert_equal "human:tosin", link.verified_by
    assert link.verified?
    assert_empty link.evidence, "an existing link gets the quote only when it's published"
  end

  test "matching an existing pending link defers candidate attributes until publication" do
    link = FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle),
      relationship_type: "owns", description: "Curated description", ownership_pct: 40)
    c = candidate("facility_relationship", {
      "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => "Vogtle Electric Generating Plant" },
      "relationship_type" => "owns",
      "description" => "Candidate description",
      "ownership_pct" => 75
    })

    match!

    assert c.reload.status_matched?
    assert_equal link.id, c.subject_id
    assert_equal [ "Curated description", 40 ], link.reload.slice(:description, :ownership_pct).values
  end

  test "a link to a record that needs review waits in review too" do
    vogtle_site!
    candidate("facility", facility_payload("Vogtle 1", "05000424"))
    link = candidate("facility_relationship", {
      "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => "Vogtle 1", "nrc_docket" => "05000424" },
      "relationship_type" => "operates"
    })

    match!

    assert link.reload.status_needs_review?
    assert_match "looks like a unit of Plant Vogtle", link.notes
  end

  test "an operator becomes an operates link on the unit under its site" do
    site = vogtle_site!
    candidate("organization", { "name" => "Example Nuclear Operating Co." })
    candidate("facility", facility_payload("Vogtle 3", "05200025"))
    link = candidate("facility_relationship", {
      "organization" => { "name" => "Example Nuclear Operating Co." },
      "facility" => { "name" => "Vogtle 3", "nrc_docket" => "05200025" },
      "relationship_type" => "operates"
    })

    match!

    record = FacilityRelationship.find(link.reload.subject_id)
    assert record.operates?
    assert_equal [ "Example Nuclear Operating Co.", site.id ], [ record.organization.name, record.facility.parent_id ]
    assert record.organization.pending?
  end

  test "a link with a missing end goes to review" do
    link = candidate("facility_relationship", { "organization" => { "name" => "TerraPower" }, "relationship_type" => "operates" })

    match!

    assert link.reload.status_needs_review?
    assert_equal "payload has no facility", link.notes
  end

  test "a payload the directory rejects goes to review with the reason" do
    c = candidate("organization", { "name" => "Brand New Co", "favourite_colour" => "blue" })

    run = match!

    assert c.reload.status_needs_review?
    assert_match "unknown attributes: favourite_colour", c.notes
    assert_equal 1, run.stats["write_errors"]
  end

  test "a company given only by website matches by that website's domain" do
    c = candidate("organization", { "name" => "TP Nuclear Holdings", "website" => "https://www.terrapower.com/about" })

    run = match!

    assert_equal organizations(:terrapower).id, c.reload.subject_id
    assert_match "by domain", c.notes
    assert_equal 1, run.stats["matched"]
  end

  test "a match run refuses to overlap another match run" do
    # A separate Postgres session plays the other run (tests share one pooled connection).
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: config[:host], port: config[:port], user: config[:username], password: config[:password],
      dbname: config[:database])
    other.exec("SELECT pg_advisory_lock(#{Zlib.crc32('data_quality:match')})")

    error = assert_raises(RuntimeError) { match! }
    assert_equal "Another match run is already in progress", error.message
  ensure
    other&.close
  end

  test "an explicit nil domain prevents website matching" do
    c = candidate("organization", { "name" => "Lumen Fission", "domain" => nil,
      "website" => "https://www.terrapower.com" })

    match!

    record = Organization.find(c.reload.subject_id)
    assert_not_equal organizations(:terrapower).id, record.id
    assert_nil record.domain
    assert_equal "https://www.terrapower.com", record.website
  end

  test "rerunning leaves candidates that already moved on alone" do
    candidate("facility", facility_payload("Arkansas Nuclear 1", "05000313"))
    match!

    assert_no_difference [ "Facility.count", "Evidence.count" ] do
      assert_equal 0, match!.stats["candidates"]
    end
  end
end
