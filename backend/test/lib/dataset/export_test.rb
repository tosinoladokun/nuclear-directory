require "test_helper"

# The open dataset release (#254): published facts only, no internal fields,
# no third-party quote text, and files that describe exactly what's there.
class Dataset::ExportTest < ActiveSupport::TestCase
  BY = "human:tosin"
  Export = Dataset::Export
  INTERNAL = %w[confidence verified_by verification_status quote content_text crawl_status etag status_reason domain].freeze

  setup do
    @dir = Dir.mktmpdir("dataset")
    @source = sources(:press_release)
    @kairos = Organization.create!(name: "Kairos Power", domain: "kairospower.com", verification_status: "verified", verified_by: BY,
      verified_at: Time.utc(2026, 10, 10))
    @kairos.aliases.create!(alias: "Kairos Power")
    @kairos.aliases.create!(alias: "Kairos")
    @kairos.evidence.create!(source: @source, quote: "Kairos Power develops reactors.", found_by: "human", confidence: 1)
    @hidden = Organization.create!(name: "Hidden Co")
    @hidden.evidence.create!(source: sources(:nrc), quote: "Hidden.", found_by: "crawler", confidence: 0.5)
    @site = Facility.create!(name: "Hermes", facility_type: "research_reactor", state: "TN", verification_status: "verified", verified_by: BY)
    @site.evidence.create!(source: @source, quote: "Hermes, in Oak Ridge, Tennessee.", found_by: "human", confidence: 1)
    @owns = FacilityRelationship.create!(organization: @kairos, facility: @site, relationship_type: "owns", ownership_pct: 100,
      verification_status: "verified", verified_by: BY)
    @owns.evidence.create!(source: @source, quote: "Kairos Power owns Hermes.", found_by: "human", confidence: 1)
    @doe = Organization.create!(name: "U.S. Department of Energy", verification_status: "verified", verified_by: BY)
    award = Source.create!(url: "https://www.energy.gov/ne/articles/kairos", source_kind: "web_page", domain: "energy.gov", title: "DOE award",
      fetched_at: Time.utc(2026, 10, 12))
    funds = Relationship.create!(from_organization: @doe, to_organization: @kairos, relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
    funds.evidence.create!(source: award, quote: "DOE awards Kairos Power.", found_by: "human", confidence: 1)
    role = @kairos.organization_roles.create!(role: Role.find_or_create_by!(key: "reactor_vendor") { |r| r.name = "Reactor vendor" },
      verification_status: "verified", verified_by: BY)
    role.evidence.create!(source: @source, quote: "Kairos Power develops reactors.", found_by: "human", confidence: 1)
  end

  teardown { FileUtils.rm_rf(@dir) }

  def export(**options) = Export.new(@dir, version: "2026.12", released_on: Date.new(2026, 12, 7), **options).write!
  def read(name) = CSV.read(File.join(@dir, "#{name}.csv"), headers: true)
  def file(name) = File.read(File.join(@dir, name))

  test "writes the five tables as CSV and JSON, published facts only, with every column documented" do
    result = export

    assert_equal %w[companies facilities relationships sources evidence], result[:counts].keys
    Export::TABLES.each do |table, columns|
      assert_equal columns.keys, read(table).headers, "#{table}.csv has exactly the documented columns"
      JSON.parse(file("#{table}.json")).each { |row| assert_equal columns.keys.sort, row.keys.sort }
    end
    assert_equal [ "kairos-power", "u-s-department-of-energy" ], read("companies").map { |row| row["slug"] }
    assert_not_includes file("companies.json"), "Hidden Co"
    assert_not_includes file("sources.csv"), "nrc.gov", "a source that only backs an unpublished fact isn't listed"
  end

  test "exports no quote text and no internal field" do
    export

    %w[develops owns awards].each { |word| assert_not_includes Dir[File.join(@dir, "*")].map { |path| File.read(path) }.join, "Kairos Power #{word} " }
    Export::TABLES.each_value { |columns| assert_empty columns.keys & INTERNAL }
  end

  test "companies carry their aliases, buckets, roles and checked date; their own name isn't an alias" do
    export
    kairos = JSON.parse(file("companies.json")).find { |row| row["slug"] == "kairos-power" }

    assert_equal [ "Kairos" ], kairos["aliases"]
    assert_equal [ "reactor_vendor" ], kairos["roles"]
    assert_includes kairos["buckets"], "reactor-developers"
    assert_equal "2026-10-10", kairos["checked_on"]
    assert_equal "https://nuclear-directory.org/companies/kairos-power", kairos["url"]
    assert_equal "Kairos", read("companies").find { |row| row["slug"] == "kairos-power" }["aliases"]
  end

  test "relationships name their ends by table and slug" do
    export
    rows = read("relationships").index_by { |row| row["id"] }

    assert_equal [ "owns", "kairos-power", "facilities", "hermes", "100.0" ], rows["facility-#{@owns.id}"].fields(*%w[type from_slug to_table to_slug ownership_pct])
    assert_equal [ "funds", "u-s-department-of-energy", "companies", "kairos-power" ],
      rows.values.find { |row| row["type"] == "funds" }.fields(*%w[type from_slug to_table to_slug])
  end

  test "evidence ties each fact, category included, to its sources" do
    export
    rows = read("evidence").map { |row| row.fields(*%w[fact_table fact_key fact_part]) }

    assert_includes rows, [ "companies", "kairos-power", nil ]
    assert_includes rows, [ "companies", "kairos-power", "role:reactor_vendor" ]
    assert_includes rows, [ "relationships", "facility-#{@owns.id}", nil ]
    assert_equal rows.size, rows.uniq.size, "one row per fact and source"
  end

  test "sources name their publisher and document type, from the list or a company's own domain" do
    own = Source.create!(url: "https://news.kairospower.com/hermes", source_kind: "web_page", domain: "news.kairospower.com")
    @kairos.evidence.create!(source: own, quote: "Kairos Power builds Hermes.", found_by: "human", confidence: 1)
    result = export
    rows = read("sources").index_by { |row| row["url"] }

    assert_equal [ "U.S. Department of Energy", "government_page", "2026-10-12" ],
      rows["https://www.energy.gov/ne/articles/kairos"].fields("publisher", "document_type", "accessed_on")
    assert_equal [ "Kairos Power", "company_page" ], rows[own.url].fields("publisher", "document_type"), "a subdomain of its own domain"
    assert_equal [ "terrapower.com" ], result[:unknown_publishers], "TerraPower isn't a published company here"
  end

  test "an unknown domain is shown as itself and reported, never guessed" do
    @kairos.update!(domain: nil)
    result = export

    assert_equal [ "terrapower.com" ], result[:unknown_publishers]
    assert_equal [ "terrapower.com", "web_page" ], read("sources").find { |row| row["url"] == @source.url }.fields("publisher", "document_type")
  end

  test "describes itself: README, dictionary, citation, licence, Zenodo metadata" do
    export

    readme = file("README.md")
    assert_includes readme, "This licence covers the data in this repository. The website's code is not covered."
    assert_includes readme, "Oladokun, T. (2026). *Nuclear Directory: US nuclear supply chain dataset* (Version 2026.12)"
    assert_match "| `companies` | 2 |", readme
    assert_no_match(/open source/i, Dir[File.join(@dir, "*"), File.join(@dir, ".*")].select { |path| File.file?(path) }.map { |path| File.read(path) }.join)
    dictionary = file("DATA-DICTIONARY.md")
    Export::TABLES.each_value { |columns| columns.each_key { |column| assert_includes dictionary, "| `#{column}` |" } }
    citation = YAML.safe_load(file("CITATION.cff"), permitted_classes: [ Date ])
    assert_equal [ "dataset", "2026.12", "CC-BY-4.0", "Oladokun" ], [ citation["type"], citation["version"], citation["license"], citation.dig("authors", 0, "family-names") ]
    assert_nil citation.dig("authors", 0, "orcid"), "no ORCID until Tosin has one"
    assert_equal "Nuclear Directory", citation.dig("preferred-citation", "publisher", "name")
    zenodo = JSON.parse(file(".zenodo.json"))
    assert_equal [ "dataset", "cc-by-4.0", "Oladokun, Tosin" ], [ zenodo["upload_type"], zenodo["license"], zenodo.dig("creators", 0, "name") ]
    assert_includes file("LICENSE"), "https://creativecommons.org/licenses/by/4.0/legalcode"
  end

  test "shows what the site shows: an unsourced company keeps only its identity; unsourced tags, units and links are left out" do
    @doe.update!(description: "Funds research.", website: "https://www.energy.gov") # no evidence on DOE itself
    unsourced_unit = Facility.create!(name: "Hermes 1", parent: @site, nrc_docket: "05007513", verification_status: "verified", verified_by: BY)
    @kairos.organization_technologies.create!(technology: Technology.find_or_create_by!(key: "fission") { |t| t.name = "Fission" },
      verification_status: "verified", verified_by: BY)
    export
    companies = JSON.parse(file("companies.json")).index_by { |row| row["slug"] }

    assert_equal [ "U.S. Department of Energy", nil, nil ], companies["u-s-department-of-energy"].values_at("name", "description", "website")
    assert_empty companies["kairos-power"]["technologies"], "a technology without a quote isn't listed"
    assert_not_includes read("facilities").map { |row| row["slug"] }, unsourced_unit.slug
  end

  test "a pending site public through its unit shows only its identity, and the unit in full" do
    site = Facility.create!(name: "Vogtle", facility_type: "power_reactor", state: "GA", city: "Waynesboro")
    site.evidence.create!(source: @source, quote: "Vogtle, Waynesboro.", found_by: "crawler", confidence: 0.5)
    unit = Facility.create!(name: "Vogtle 3", parent: site, nrc_docket: "05200025", status: "operating", capacity_mw: 1114,
      facility_type: "power_reactor", verification_status: "verified", verified_by: BY)
    unit.evidence.create!(source: @source, quote: "Vogtle 3 operates.", found_by: "human", confidence: 1)
    export
    rows = read("facilities").index_by { |row| row["slug"] }

    assert_equal [ "site", nil, nil, nil ], rows[site.slug].fields("level", "facility_type", "state", "city"), "a pending site's details stay hidden"
    assert_equal [ "unit", site.slug, "operating", "1114.0" ], rows[unit.slug].fields("level", "site_slug", "status", "capacity_mw")
    assert_not read("evidence").any? { |row| row["fact_key"] == site.slug }, "nor is its evidence listed"
  end

  test "a sourced link to a verified site without its own source is kept; the site's details aren't" do
    @site.evidence.destroy_all
    export

    assert_includes read("relationships").map { |row| row["id"] }, "facility-#{@owns.id}"
    assert_includes read("evidence").map { |row| row["fact_key"] }, "facility-#{@owns.id}"
    assert_equal [ nil, nil ], read("facilities").find { |row| row["slug"] == @site.slug }.fields("facility_type", "state")
  end

  test "a site's capacity is its operating units' total, as its page shows it" do
    site = Facility.create!(name: "Plant Vogtle", facility_type: "power_reactor", verification_status: "verified", verified_by: BY)
    site.evidence.create!(source: @source, quote: "Plant Vogtle.", found_by: "human", confidence: 1)
    { "Vogtle 3" => [ "operating", 1114 ], "Vogtle 4" => [ "operating", 1114 ], "Vogtle 1" => [ "shut_down", 1150 ] }.each_with_index do |(name, (status, mw)), i|
      Facility.create!(name:, parent: site, nrc_docket: "0520002#{i}", status:, capacity_mw: mw, verification_status: "verified", verified_by: BY)
        .evidence.create!(source: @source, quote: "#{name}.", found_by: "human", confidence: 1)
    end
    export

    assert_equal "2228.0", read("facilities").find { |row| row["slug"] == site.slug }["capacity_mw"]
  end

  test "latest.json gives the site this release's version, counts and file links" do
    export
    latest = JSON.parse(file("latest.json"))

    assert_equal [ "2026.12", "2026-12-07", nil ], latest.values_at("version", "released_on", "doi"), "no version DOI until Zenodo archives it"
    assert_equal %w[companies facilities relationships sources evidence], latest["counts"].keys
    assert_equal 2, latest.dig("counts", "companies")
    assert_equal "https://raw.githubusercontent.com/tosinoladokun/nuclear-directory-data/v2026.12/companies.csv", latest.dig("files", "companies", "csv")
  end

  test "the concept DOI and ORCID come from the environment once they exist" do
    with_env("DATASET_CONCEPT_DOI" => "10.5281/zenodo.1234567", "DATASET_AUTHOR_ORCID" => "0000-0002-1825-0097") { export }

    assert_includes file("README.md"), "https://doi.org/10.5281/zenodo.1234567"
    assert_equal "https://orcid.org/0000-0002-1825-0097", YAML.safe_load(file("CITATION.cff"), permitted_classes: [ Date ]).dig("authors", 0, "orcid")
    assert_equal "0000-0002-1825-0097", JSON.parse(file(".zenodo.json")).dig("creators", 0, "orcid")
  end

  test "the changelog says what changed since the previous release, and keeps the history" do
    previous = Dir.mktmpdir("previous")
    Export.new(previous, version: "2026.11", released_on: Date.new(2026, 11, 2)).write!
    Organization.create!(name: "X-energy", verification_status: "verified", verified_by: BY)
      .evidence.create!(source: @source, quote: "X-energy.", found_by: "human", confidence: 1)

    export(previous:)
    changelog = file("CHANGELOG.md")

    assert_match "## 2026.12 (2026-12-07)", changelog
    assert_match "| `companies` | 3 | 1 | 0 |", changelog
    assert_match "- New companies: x-energy", changelog
    assert_match "Compared with 2026.11.", changelog
    assert_match "## 2026.11 (2026-11-02)", changelog, "earlier releases stay below"
    assert_equal "2026.12", JSON.parse(file("manifest.json"))["version"]
  ensure
    FileUtils.rm_rf(previous)
  end

  private
    def with_env(values)
      old = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      old.each { |key, value| ENV[key] = value }
    end
end
