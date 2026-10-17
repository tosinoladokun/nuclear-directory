require "test_helper"

# The open dataset dry run (#254): published facts only, no internal fields.
class Dataset::ExportTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @dir = Dir.mktmpdir("dataset")
    @source = sources(:press_release)
    @kairos = Organization.create!(name: "Kairos Power", verification_status: "verified", verified_by: BY, verified_at: Time.utc(2026, 10, 10))
    @kairos.aliases.create!(alias: "Kairos Power")
    @kairos.aliases.create!(alias: "Kairos")
    @kairos.evidence.create!(source: @source, quote: "Kairos Power develops reactors.", found_by: "human", confidence: 1)
    @hidden = Organization.create!(name: "Hidden Co")
    @hidden.evidence.create!(source: sources(:nrc), quote: "Hidden.", found_by: "crawler", confidence: 0.5)
    @hermes = Facility.create!(name: "Hermes", facility_type: "research_reactor", verification_status: "verified", verified_by: BY)
    link = FacilityRelationship.create!(organization: @kairos, facility: @hermes, relationship_type: "owns",
      verification_status: "verified", verified_by: BY)
    link.evidence.create!(source: @source, quote: "Kairos Power owns Hermes.", found_by: "human", confidence: 1)
  end

  teardown { FileUtils.rm_rf(@dir) }

  def export = Dataset::Export.new(@dir).write!

  def read(name) = CSV.read(File.join(@dir, "#{name}.csv"), headers: true)

  test "writes each record type as CSV and JSON, published facts only" do
    counts = export

    assert_equal [ "kairos-power" ], read("companies").map { |row| row["slug"] }
    assert_equal [ "hermes" ], read("plants").map { |row| row["slug"] }
    assert_equal [ [ "kairos-power", "hermes", "owns" ] ], read("plant_links").map { |row| row.values_at("company", "plant", "type") }
    assert_equal 1, counts["companies"]
    json = JSON.parse(File.read(File.join(@dir, "companies.json")))
    assert_equal [ "Kairos" ], json.sole["aliases"], "the name itself isn't repeated as an alias"
    assert_equal "2026-10-10", json.sole["checked_on"]
    assert File.exist?(File.join(@dir, "README.md"))
  end

  test "every published fact's evidence is there, tied to a listed source; a hidden fact's isn't" do
    export

    evidence = read("evidence")
    assert_equal [ [ "companies", "kairos-power" ], [ "plant_links", FacilityRelationship.sole.id.to_s ] ],
      evidence.map { |row| row.values_at("fact_file", "fact_key") }
    assert_equal [ @source.url ], read("sources").map { |row| row["url"] }
    assert evidence.none? { |row| row["quote"] == "Hidden." }
  end

  test "no internal fields in any file" do
    export

    text = Dir[File.join(@dir, "*.{csv,json}")].map { |path| File.read(path) }.join
    [ "verified_by", "human:tosin", "confidence", "crawl_status", "content_text", "verification_status" ].each do |internal|
      assert_not_includes text, internal
    end
  end
end
