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
    assert_equal 5, plugin.new_sources_per_run
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
    funder, company, link, term = plugin.extract(projects.find_by!(url: SHINE), nil)

    assert_equal({ "name" => "Advanced Research Projects Agency-Energy", "aliases" => [ "ARPA-E" ] }, funder[:payload])
    assert_equal({ "name" => "SHINE Technologies, LLC" }, company[:payload])
    assert_equal "Advanced Research Projects Agency-Energy", link[:payload].dig("from_organization", "name")
    assert_equal [ "award", "4030306", "NEWTON", SHINE ], term[:payload].values_at("term_type", "amount_usd", "program", "external_id")
  end

  test "two projects for one lab give the same link wording, each its own award" do
    crawl
    argonne = projects.select { |source| source.content_text.include?("Organization: Argonne National Laboratory") }
    assert_equal 2, argonne.size
    links, terms = argonne.map { |source| plugin.extract(source, nil) }.then { |all| [ all.map { |c| c[2][:payload] }, all.map { |c| c[3][:payload]["external_id"] } ] }
    assert_equal 1, links.uniq.size
    assert_equal 2, terms.uniq.size
  end

  test "a name with its acronym in brackets keeps the acronym as an alias" do
    source = Source.new(url: "https://x", content_text: "Project: X | Organization: Lawrence Livermore National Laboratory (LLNL) | Status: Active")
    assert_equal({ "name" => "Lawrence Livermore National Laboratory", "aliases" => [ "LLNL" ] }, plugin.extract(source, nil)[1][:payload])
  end

  test "DQ's names: trailing acronym to an alias, spaces squished, a mid-name acronym left alone" do
    names = {
      "Idaho National Laboratory (INL)" => { "name" => "Idaho National Laboratory", "aliases" => [ "INL" ] },
      "Princeton Plasma Physics Laboratory (PPPL)  " => { "name" => "Princeton Plasma Physics Laboratory", "aliases" => [ "PPPL" ] },
      "Commonwealth Fusion Systems (CFS)" => { "name" => "Commonwealth Fusion Systems", "aliases" => [ "CFS" ] },
      "General Electric (GE) Global Research" => { "name" => "General Electric (GE) Global Research" }
    }
    names.each do |raw, expected|
      row = { "attributes" => { "fields" => { "title" => "X", "urls" => [ "/programs-and-initiatives/search-all-projects/x" ], "organization" => [ { "attributes" => { "title" => raw } } ] } } }
      _url, line = plugin.send(:project_line, row, "nuclear fusion")
      assert_equal expected, plugin.extract(Source.new(url: "https://x", content_text: line), nil)[1][:payload], raw
    end
  end

  test "an unchanged project's read is refreshed; robots denial needs a person" do
    crawl
    travel 1.day do
      crawl
      assert projects.all? { |source| source.fetched_at.to_date == Date.current }
    end
    travel 2.days do
      stub_request(:get, "https://arpa-e.energy.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /JSONAPI/\n")
      crawl
      assert Source.find_by!(url: Plugin::API_URL).crawl_needs_human?
    end
  end

  test "a cancelled project proposes nothing" do
    source = Source.new(content_text: "Project: X | Organization: Y Inc | Status: Cancelled | Area: nuclear fission")
    assert_empty plugin.extract(source, nil)
  end
end
