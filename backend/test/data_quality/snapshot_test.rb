require "test_helper"

class DataQuality::SnapshotTest < ActiveSupport::TestCase
  FILE = "https://www.example.gov/data.xlsx".freeze

  setup do
    stub_request(:get, "https://www.example.gov/robots.txt").to_return(status: 404)
  end

  test "a converted file's text with NUL bytes is stored without them, hashed as stored (#981)" do
    bytes = "PK\x00\x01raw".b
    stub_request(:get, FILE).to_return(body: bytes, headers: { "Content-Type" => "application/octet-stream" })
    source = Source.create!(url: FILE, source_kind: "eia_generators")
    received = nil

    result = DataQuality::Snapshot.take(source, fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), binary: true) do |body|
      received = body
      "Plant A\0, 100 MW"
    end

    assert_equal :changed, result
    assert_equal bytes, received, "the converter gets the file's own bytes"
    source.reload
    assert_equal "Plant A, 100 MW", source.content_text
    assert_equal Digest::SHA256.hexdigest("Plant A, 100 MW"), source.content_sha256
  end
end
