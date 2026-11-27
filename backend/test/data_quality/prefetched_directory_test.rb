require "test_helper"

# #1008: the inbox's prefetched directory answers as DirectoryClient does.
class DataQuality::PrefetchedDirectoryTest < ActiveSupport::TestCase
  test "a unit's site by a padded EIA plant ID is the one the directory finds (trimmed, as facility(eia_plant_id:) does; Copilot)" do
    page = Source.create!(url: "https://www.eia.gov/test/plants", source_kind: "dummy", crawl_status: "ok", content_sha256: "s", content_text: "q")
    unit = Facility.create!(name: "Padded Unit", nrc_docket: "05009998", verification_status: "verified", verified_by: "human:tosin")
    site = Facility.create!(name: "Padded Site", eia_plant_id: "6153", verification_status: "verified", verified_by: "human:tosin")
    claim = Candidate.create!(source: page, kind: "facility", quote: "q", status: "matched", subject_type: "Facility", subject_id: unit.id,
      payload: { "name" => unit.name, DataQuality::DirectoryClient::ENRICHMENT_KEY => { "eia_plant_id" => " 6153 " } })

    assert_equal site.id, DataQuality::DirectoryClient.new.site_for_unit(claim)
    assert_equal site.id, DataQuality::PrefetchedDirectory.new.prefetch([ claim ]).site_for_unit(claim)
  end
end
