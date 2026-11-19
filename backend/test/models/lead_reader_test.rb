require "test_helper"

# Add a lead as a prompt (PM, 18 Nov): free text read into companies, each with its site and a hint.
class LeadReaderTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:companies, :error) do
    def structured(**) = error ? raise(error) : Struct.new(:data).new({ "companies" => companies })
  end

  test "free text: names kept as written, a site only when given, the rest as a hint" do
    client = FakeClient.new([
      { "name" => "Aalo Atomics", "website" => "aalo.com", "hint" => "Austin microreactor startup" },
      { "name" => "Cameco", "website" => nil, "hint" => nil },
      { "name" => "Bad Site Co", "website" => "javascript:alert(1)", "hint" => nil }
    ])
    items = LeadReader.new(client:).call("Aalo, the Austin microreactor startup, aalo.com\nCameco")
    assert_equal [ [ "Aalo Atomics", "https://aalo.com", "Austin microreactor startup" ], [ "Cameco", nil, nil ], [ "Bad Site Co", nil, nil ] ],
      items.map { |item| [ item.name, item.website, item.hint ] }
    assert_equal "succeeded", CrawlRun.where(source_kind: "add_a_lead").last.status, "its model use counts in the budget"
  end

  test "when the model fails, each line is read by hand: a link is the site" do
    client = FakeClient.new(nil, DataQuality::OpenRouter::Client::RequestError.new("down"))
    items = LeadReader.new(client:).call("Aalo Atomics: https://www.aalo.com/\nCameco\nhttps://www.oklo.com/")
    assert_equal [ [ "Aalo Atomics", "https://www.aalo.com/" ], [ "Cameco", nil ], [ "oklo.com", "https://www.oklo.com/" ] ],
      items.map { |item| [ item.name, item.website ] }
  end
end
