require "test_helper"

# #950: a release's version DOI, read from Zenodo's public records API and
# checked at doi.org before it's trusted.
class Dataset::ZenodoTest < ActiveSupport::TestCase
  SEARCH = "https://zenodo.org/api/records?q=conceptrecid%3A23703377&all_versions=true&sort=mostrecent&size=25".freeze

  def hits(*versions)
    { hits: { hits: versions.map { |version, id| { id:, doi: "10.5281/zenodo.#{id}", metadata: { version: } } } } }.to_json
  end

  test "finds the version's DOI once doi.org resolves it" do
    stub_request(:get, SEARCH).to_return(status: 200, body: hits([ "2026.12", 24000001 ], [ "2026.11", 23703378 ]))
    stub_request(:head, "https://doi.org/10.5281/zenodo.24000001").to_return(status: 302, headers: { "Location" => "https://zenodo.org/records/24000001" })

    assert_equal "10.5281/zenodo.24000001", Dataset::Zenodo.new.version_doi("2026.12")
  end

  test "accepts the tag as Zenodo's version name" do
    stub_request(:get, SEARCH).to_return(status: 200, body: hits([ "v2026.12", 24000001 ]))
    stub_request(:head, "https://doi.org/10.5281/zenodo.24000001").to_return(status: 302)

    assert_equal "10.5281/zenodo.24000001", Dataset::Zenodo.new.version_doi("2026.12")
  end

  test "nil while Zenodo has no such version, or its DOI doesn't resolve yet" do
    stub_request(:get, SEARCH).to_return(status: 200, body: hits([ "2026.11", 23703378 ]))
    assert_nil Dataset::Zenodo.new.version_doi("2026.12")

    stub_request(:get, SEARCH).to_return(status: 200, body: hits([ "2026.12", 24000001 ]))
    stub_request(:head, "https://doi.org/10.5281/zenodo.24000001").to_return(status: 404)
    assert_nil Dataset::Zenodo.new.version_doi("2026.12")
  end

  test "an error from Zenodo or the network is a Zenodo::Error" do
    stub_request(:get, SEARCH).to_return(status: 503, body: "busy")
    assert_raises(Dataset::Zenodo::Error) { Dataset::Zenodo.new.version_doi("2026.12") }

    stub_request(:get, SEARCH).to_timeout
    assert_raises(Dataset::Zenodo::Error) { Dataset::Zenodo.new.version_doi("2026.12") }
  end
end
