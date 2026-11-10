require "test_helper"

class DataQuality::Plugins::LeadFinderTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::LeadFinder
  HOME = "https://www.freshfission.example".freeze
  PAGE = "<html><body><h1>Fresh Fission</h1><p>Fresh Fission designs microreactors for remote sites.</p>" \
    "<p>Fresh Fission Inc., 1 Main St, Austin, TX 78701</p></body></html>".freeze

  setup do
    stub_request(:get, "#{HOME}/robots.txt").to_return(status: 404)
    stub_request(:get, HOME).to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
    @searched = []
    @pipeline_runs = 0
  end

  def lead(name, url: nil) = Lead.sighted!(name:, kind: "company", key: "admin:#{name}", label: "Suggested by Tosin", url:)
  def finder(results: []) = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil,
    search: ->(query) { @searched << query; results }, pipeline: ->(plugin) { @pipeline_runs += 1; DataQuality::Stages::Extract.call(plugin:) })

  test "a website given: checked on its home page and proposed as a new company" do
    result = Plugin.call(lead("Fresh Fission", url: "#{HOME}/about").id, finder: finder)
    assert_equal :proposed, result.outcome
    assert_equal "https://www.freshfission.example", result.website
    claim = Candidate.find(result.candidate_id)
    assert_equal({ "name" => "Fresh Fission", "website" => "https://www.freshfission.example" }, claim.payload)
    assert_equal "Fresh Fission designs microreactors for remote sites.", claim.quote
    assert_empty @searched, "a first-party site needs no search"
  end

  test "a name only: found by the search API, then checked" do
    result = Plugin.call(lead("Fresh Fission").id, finder: finder(results: [ "https://www.linkedin.com/company/fresh", "#{HOME}/team" ]))
    assert_equal :proposed, result.outcome
    assert_equal [ "\"Fresh Fission\" nuclear" ], @searched
    assert_equal 1, result.found["searched"], "LinkedIn is never a website; results themselves are never kept (Brave's terms)"
    refute_includes result.found.to_s, "linkedin"
  end

  test "a LinkedIn link gives the name only and is never fetched" do
    result = Plugin.call(lead("https://www.linkedin.com/company/fresh-fission/").id, finder: finder(results: [ HOME ]))
    assert_equal "Fresh Fission", result.name
    assert_equal :proposed, result.outcome
    assert_not_requested :get, %r{linkedin\.com}
  end

  test "a news link: the site its About paragraph links" do
    news = "https://www.prnewswire.com/news-releases/fresh-1.html"
    stub_request(:get, "https://www.prnewswire.com/robots.txt").to_return(status: 404)
    stub_request(:get, news).to_return(body: "<html><body><p>News.</p><p><b>About Fresh Fission</b></p>" \
      "<p>Fresh Fission builds reactors. <a href=\"#{HOME}/\">freshfission</a> <a href=\"https://twitter.com/fresh\">X</a></p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = Plugin.call(lead("Fresh Fission", url: news).id, finder: finder)
    assert_equal :proposed, result.outcome
    assert_equal [ "https://www.freshfission.example" ], result.found["given"]
  end

  test "a company we have, by name or by its website, is a duplicate" do
    org = Organization.create!(name: "Fresh Fission", verification_status: "verified", verified_by: "human:tosin")
    org.aliases.find_or_create_by!(alias: "Fresh Fission")
    result = Plugin.call(lead("Fresh Fission").id, finder: finder)
    assert_equal [ :duplicate, org.id ], [ result.outcome, result.organization_id ]

    other = Organization.create!(name: "Old Name Fission", website: HOME, domain: "freshfission.example", verification_status: "verified", verified_by: "human:tosin")
    result = Plugin.call(lead("New Fission", url: HOME).id, finder: finder)
    assert_equal [ :duplicate, other.id ], [ result.outcome, result.organization_id ]
  end

  test "a site that states no nuclear work, or isn't the company, isn't confirmed" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>Fresh Fission sells solar panels. Austin, TX 78701</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = Plugin.call(lead("Fresh Fission", url: HOME).id, finder: finder)
    assert_equal :unconfirmed, result.outcome
    assert_equal "not_nuclear", result.found["checked"].sole["verdict"]

    result = Plugin.call(lead("Other Atom", url: HOME).id, finder: finder)
    assert_equal "not_named", result.found["checked"].sole["verdict"]
    assert_equal 0, @pipeline_runs
  end

  test "nothing to go on: unconfirmed, with no search without a key" do
    result = Plugin.call(lead("Ghost Nuclear").id, finder: Plugin.new(search_key: nil))
    assert_equal [ :unconfirmed, "No website found" ], [ result.outcome, result.reason ]
  end
end
