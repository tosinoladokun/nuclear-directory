require "test_helper"

# The fixture is the first 6 of ARPA-E's real Nuclear Fission projects from
# its project index (fetched 2026-10-26 with the plug-in's user agent),
# trimmed to the fields the plug-in reads.
class DataQuality::Plugins::ArpaEProjectsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::ArpaEProjects
  SHINE = "https://arpa-e.energy.gov/programs-and-initiatives/search-all-projects/reduce-recover-elements-destroy-undesirables-create-energy".freeze

  setup do
    stub_request(:get, "https://arpa-e.energy.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /admin/\n")
    @fission = stub_request(:get, %r{technology_sub%5D=74}).to_return(body: file_fixture("arpa_e/fission.json").read)
    @fusion = stub_request(:get, %r{technology_sub%5D=81}).to_return(body: { data: [] }.to_json)
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def projects = Source.where(source_kind: "arpa_e_projects")

  test "is the plug-in for arpa_e_projects, nightly, capped" do
    assert_instance_of Plugin, DataQuality::Plugin.for("arpa_e_projects")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "arpa_e_projects"
    assert_equal 15, plugin.new_sources_per_run
  end

  test "reads the fission and fusion projects once a day, each stored at its page, only when new or changed" do
    first = crawl
    second = crawl

    assert_equal({ "index" => "ok", "projects" => 6, "new" => 6 }, first.stats)
    assert_equal "skipped_recent", second.stats["index"]
    assert_requested @fission, times: 1
    assert_equal 6, projects.count
    line = projects.find_by!(url: SHINE).content_text
    assert_match "Organization: SHINE Technologies, LLC", line
    assert_match "Award: $4,030,306", line
    assert_match "Program: NEWTON", line
  end

  test "a block stops the crawl" do
    stub_request(:get, %r{\A#{Regexp.escape(Plugin::API_URL)}}).to_return(status: 403, body: "Forbidden")

    assert_equal "ARPA-E blocked us", crawl.stats["stopped"]
    assert_empty projects
  end

  test "each project: the organization and ARPA-E's funds link, described as ARPA-E states the award" do
    crawl
    company, link = plugin.extract(projects.find_by!(url: SHINE), nil)

    assert_equal({ "name" => "SHINE Technologies, LLC" }, company[:payload])
    assert_equal "Advanced Research Projects Agency-Energy (ARPA-E)", link[:payload].dig("from_organization", "name")
    assert_match(/\AARPA-E nuclear fission award of \$4,030,306 \(NEWTON\) for "REDUCE:/, link[:payload]["description"])
  end

  test "a cancelled project proposes nothing" do
    source = Source.new(content_text: "Project: X | Organization: Y Inc | Status: Cancelled | Area: nuclear fission")
    assert_empty plugin.extract(source, nil)
  end
end
