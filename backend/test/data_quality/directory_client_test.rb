require "test_helper"
require_relative "support/fake_directory"
require_relative "support/dummy_plugin"

# DirectoryClient against the real Directory::Lookup and Directory::FactWriter,
# so the module and the directory can't silently drift apart. (Tests may use
# directory models; only module code is held to the boundary.)
class DataQuality::DirectoryClientTest < ActiveSupport::TestCase
  include ReviewHelpers

  setup do
    @client = DataQuality::DirectoryClient.new
    @run = CrawlRun.create!(stage: "verify", source_kind: "web_page", model: "vendor/verifier")
  end

  def candidate(kind, payload, quote: "TerraPower, founded by Bill Gates")
    Candidate.create!(source: sources(:press_release), kind: kind, payload: payload, quote: quote)
  end

  test "finds organizations by name or alias, or by domain" do
    terrapower = @client.organization(name: "TerraPower, LLC")
    assert_equal DataQuality::DirectoryClient::Ref.new(type: "Organization", id: organizations(:terrapower).id), terrapower.ref
    assert_equal "TerraPower", terrapower.name
    assert_equal organizations(:terrapower).id, @client.organization(domain: "https://www.terrapower.com/news").id
    assert_nil @client.organization(name: "Nobody")
  end

  test "finds similar records as module values" do
    similar = @client.similar_facilities("Vogtle 3")
    assert_equal [ facilities(:vogtle).id ], similar.map(&:id)
    assert_kind_of DataQuality::DirectoryClient::Record, similar.first
  end

  test "writes a pending fact with crawler evidence" do
    result = @client.write_pending("organization", { name: "Entergy Nuclear Operations, Inc." },
      candidate: candidate("organization", {}, quote: "Entergy Nuclear Operations, Inc."), crawl_run: @run)

    assert result.success?
    assert result.created
    org = Organization.find(result.ref.id)
    assert org.pending?
    assert_equal [ "crawler", @run.id ], org.evidence.sole.slice(:found_by, :crawl_run_id).values
  end

  test "writes a new fact with its evidence, verified by the agent" do
    result = @client.write_fact(candidate("organization", { "name" => "NewCo Fission", "website" => "https://newco.example" }),
      confidence: 0.9, crawl_run: @run)

    assert result.success?, result.errors.inspect
    assert_equal "Organization", result.ref.type
    newco = Directory::Lookup.organization(id: result.ref.id)
    assert_equal "NewCo Fission", newco.name
    assert_equal "verified", newco.verification_status

    evidence = Evidence.find_by!(subject_type: "Organization", subject_id: newco.id)
    assert_equal [ "crawler", 0.9, @run.id, sources(:press_release).id ],
      [ evidence.found_by, evidence.confidence.to_f, evidence.crawl_run_id, evidence.source_id ]
    assert_equal "agent:verifier/vendor/verifier", Organization.find(newco.id).verified_by
  end

  test "a matched existing record keeps its attributes and verification when published" do
    terrapower = organizations(:terrapower)
    terrapower.update!(website: "https://curated.example")
    terrapower.verify!(by: "human:tosin")
    matched = candidate("organization", { "name" => "TerraPower", "website" => "https://terrapower.com" })
    matched.update!(status: "matched", subject_type: "Organization", subject_id: terrapower.id)

    result = nil
    assert_no_difference [ -> { Organization.count }, -> { Evidence.count } ] do
      result = @client.write_fact(matched, confidence: 0.8, crawl_run: @run)
    end

    assert result.conflict?, "a disagreement with a human-verified value is reported, for review"
    assert_equal({ "website" => [ "https://curated.example", "https://terrapower.com" ] }, result.conflicts)
    assert_equal terrapower.id, result.ref.id
    terrapower.reload
    assert_equal "https://curated.example", terrapower.website
    assert_equal "human:tosin", terrapower.verified_by
    assert_equal "verified", terrapower.verification_status
  end

  # Brand names (D1) are a person's: a licensee's legal name never replaces one.
  test "a matched company keeps its name when a person approves; the name it was found under becomes an alias" do
    terrapower = organizations(:terrapower)
    terrapower.verify!(by: "human:tosin")
    matched = candidate("organization", { "name" => "TP Fuel Holdings" })
    matched.update!(status: "matched", subject_type: "Organization", subject_id: terrapower.id)

    assert @client.write_fact(matched, confidence: 0.9, crawl_run: @run, by: "human:tosin", reason: "Approved").success?

    assert_equal "TerraPower", terrapower.reload.name
    assert_includes terrapower.aliases.pluck(:alias), "TP Fuel Holdings"
  end

  test "a matched existing facility keeps its attributes and verification when published" do
    vogtle = facilities(:vogtle)
    vogtle.verify!(by: "human:tosin")
    matched = candidate("facility", { "name" => "Vogtle Electric Generating Plant", "state" => "AL" })
    matched.update!(status: "matched", subject_type: "Facility", subject_id: vogtle.id)

    result = @client.write_fact(matched, confidence: 0.8, crawl_run: @run)

    assert_equal({ "state" => [ "GA", "AL" ] }, result.conflicts)
    assert_match "human-verified state is GA; this source says AL", result.errors.join
    vogtle.reload
    assert_equal "GA", vogtle.state
    assert_equal "human:tosin", vogtle.verified_by
    assert_equal "verified", vogtle.verification_status
  end

  test "publishing fills a human-verified record's blanks, e.g. the NRC docket of a seed plant" do
    columbia = Facility.create!(name: "Columbia Generating Station")
    columbia.verify!(by: "human:tosin")
    matched = candidate("facility", { "name" => "Columbia Generating Station", "nrc_docket" => "05000397",
      "facility_type" => "power_reactor" })
    matched.update!(status: "matched", subject_type: "Facility", subject_id: columbia.id)

    assert @client.write_fact(matched, confidence: 0.9, crawl_run: @run).success?

    columbia.reload
    assert_equal [ "05000397", "power_reactor" ], [ columbia.nrc_docket, columbia.facility_type ]
    assert_equal "human:tosin", columbia.verified_by
  end

  test "publishing a plant matched under one of its other names keeps the plant's own name" do
    crane = Facility.create!(name: "Crane Clean Energy Center")
    crane.aliases.create!(alias: "Three Mile Island Unit 1")
    matched = candidate("facility", { "name" => "Three Mile Island Unit 1", "state" => "PA" })
    matched.update!(status: "matched", subject_type: "Facility", subject_id: crane.id)

    assert @client.write_fact(matched, confidence: 0.9, crawl_run: @run).success?
    assert_equal [ "Crane Clean Energy Center", "PA" ], crane.reload.values_at(:name, :state)
  end

  test "publishing never changes a human-verified link" do
    link = FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle),
      relationship_type: "owns", description: "Curated description", ownership_pct: 40)
    link.verify!(by: "human:tosin")
    matched = candidate("facility_relationship", { "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => "Vogtle Electric Generating Plant" }, "relationship_type" => "owns",
      "description" => "Candidate description", "ownership_pct" => 75 })
    matched.update!(status: "matched", subject_type: "FacilityRelationship", subject_id: link.id)

    result = @client.write_fact(matched, confidence: 0.8, crawl_run: @run)

    assert_equal %w[description ownership_pct], result.conflicts.keys.sort
    link.reload
    assert_equal [ "Curated description", 40 ], link.slice(:description, :ownership_pct).values
    assert_equal [ "verified", "human:tosin" ], [ link.verification_status, link.verified_by ]
    assert_empty link.evidence, "nothing written, so the disagreeing quote can't raise confidence"
  end

  test "an agent never overturns a human's rejection" do
    terrapower = organizations(:terrapower)
    terrapower.reject!(by: "human:tosin")
    matched = candidate("organization", { "name" => "TerraPower Holdings" })
    matched.update!(status: "matched", subject_type: "Organization", subject_id: terrapower.id)

    result = @client.write_fact(matched, confidence: 0.9, crawl_run: @run)

    assert_not result.success?, "the write is refused, so verify sends the candidate to review"
    assert_match "rejected by human:tosin", result.errors.join
    assert terrapower.reload.rejected?
    assert_nil Directory::Lookup.organization(name: "TerraPower Holdings"), "no alias added either"
    assert_empty terrapower.evidence, "nothing written"
  end

  test "publishing a matched link applies its payload attributes" do
    link = FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle),
      relationship_type: "owns", description: "Curated description", ownership_pct: 40)
    matched = candidate("facility_relationship", {
      "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => "Vogtle Electric Generating Plant" },
      "relationship_type" => "owns",
      "description" => "Candidate description",
      "ownership_pct" => 75
    })
    matched.update!(status: "matched", subject_type: "FacilityRelationship", subject_id: link.id)

    assert @client.write_fact(matched, confidence: 0.8, crawl_run: @run).success?

    assert_equal [ "Candidate description", 75 ], link.reload.slice(:description, :ownership_pct).values
  end

  test "returns the directory's errors instead of raising" do
    result = @client.write_fact(candidate("organization", { "name" => "X", "favourite_colour" => "blue" }),
      confidence: 0.5, crawl_run: @run)

    assert_not result.success?
    assert_match "unknown attributes: favourite_colour", result.errors.join
  end

  test "the dummy plug-in runs through every stage into the real directory, published once a human approves" do
    runs = DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, verifier: PublishEverything.new)

    assert runs.all?(&:succeeded?)
    assert_equal 2, runs.last.stats["recommended"]
    assert_equal "pending", Directory::Lookup.organization(name: "NewCo Fission").verification_status,
      "proposed by match, not published by verify"

    assert approve_recommended.all?(&:ok?)

    newco = Directory::Lookup.organization(name: "NewCo Fission")
    assert_equal [ "verified", "human:tosin" ], [ newco.verification_status, newco.verified_by ]
    assert_equal %w[Acme\ Nuclear NewCo\ Fission].to_set,
      %w[Acme\ Nuclear NewCo\ Fission].filter_map { |name| Directory::Lookup.organization(name:)&.name }.to_set
  end

  test "the fakes keep the real interface's method signatures" do
    {
      "Lookup.organization" => [ Directory::Lookup.method(:organization), FakeDirectory::Lookup.instance_method(:organization) ],
      "Lookup.facility" => [ Directory::Lookup.method(:facility), FakeDirectory::Lookup.instance_method(:facility) ],
      "Lookup.similar_organizations" => [ Directory::Lookup.method(:similar_organizations),
        FakeDirectory::Lookup.instance_method(:similar_organizations) ],
      "Lookup.same_brand_organizations" => [ Directory::Lookup.method(:same_brand_organizations),
        FakeDirectory::Lookup.instance_method(:same_brand_organizations) ],
      "Lookup.brand_name" => [ Directory::Lookup.method(:brand_name), FakeDirectory::Lookup.instance_method(:brand_name) ],
      "Lookup.brand_key" => [ Directory::Lookup.method(:brand_key), FakeDirectory::Lookup.instance_method(:brand_key) ],
      "Lookup.plant_names" => [ Directory::Lookup.method(:plant_names), FakeDirectory::Lookup.instance_method(:plant_names) ],
      "Lookup.similar_facilities" => [ Directory::Lookup.method(:similar_facilities),
        FakeDirectory::Lookup.instance_method(:similar_facilities) ],
      "Lookup.facility_units" => [ Directory::Lookup.method(:facility_units),
        FakeDirectory::Lookup.instance_method(:facility_units) ],
      # FactWriter.write forwards (...) to the instance method, which has the real signature.
      "Lookup.fact_state" => [ Directory::Lookup.method(:fact_state), FakeDirectory::Lookup.instance_method(:fact_state) ],
      "Lookup.published?" => [ Directory::Lookup.method(:published?), FakeDirectory::Lookup.instance_method(:published?) ],
      "Lookup.open_corrections?" => [ Directory::Lookup.method(:open_corrections?),
        FakeDirectory::Lookup.instance_method(:open_corrections?) ],
      "Lookup.evidence" => [ Directory::Lookup.method(:evidence), FakeDirectory::Lookup.instance_method(:evidence) ],
      "Lookup.sourced?" => [ Directory::Lookup.method(:sourced?), FakeDirectory::Lookup.instance_method(:sourced?) ],
      "Lookup.fact_attributes" => [ Directory::Lookup.method(:fact_attributes),
        FakeDirectory::Lookup.instance_method(:fact_attributes) ],
      "FactWriter.write" => [ Directory::FactWriter.instance_method(:write), FakeDirectory::FactWriter.instance_method(:write) ],
      "FactWriter.while_open" => [ Directory::FactWriter.method(:while_open), FakeDirectory::FactWriter.instance_method(:while_open) ],
      "FactWriter.fill_site_from_unit" => [ Directory::FactWriter.instance_method(:fill_site_from_unit),
        FakeDirectory::FactWriter.instance_method(:fill_site_from_unit) ],
      "FactWriter.remove_evidence" => [ Directory::FactWriter.instance_method(:remove_evidence),
        FakeDirectory::FactWriter.instance_method(:remove_evidence) ]
    }.each do |name, (real, fake)|
      assert_equal real.parameters, fake.parameters, "the fake #{name} no longer matches the real one"
    end
  end
end
