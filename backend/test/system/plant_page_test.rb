require "application_system_test_case"
require_relative "../support/directory_builders"

# The plant page (#557): rows open in place, share bars sit in the owner rows, the units are one table on
# desktop and two-line rows on phones, and nothing wraps or scrolls sideways at 390 or 1440.
class PlantPageSystemTest < ApplicationSystemTestCase
  include DirectoryBuilders

  AUDIT = File.readlines(File.expand_path("../support/no_wrap_audit.js", __dir__)).reject { |line| line.start_with?("//") }.join

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/vogtle", title: "Vogtle", source_kind: "web_page", published_on: Date.new(2024, 4, 29))
    @vogtle = plant("Plant Vogtle", facility_type: "power_reactor", status: "operating", city: "Waynesboro", state: "GA")
    @vogtle.evidence.create!(source: @source, found_by: "human", confidence: 1)
    unit3 = cite!(plant("Unit 3", parent: @vogtle, reactor_type: "AP1000", capacity_mw: 1114, status: "operating", nrc_docket: "05200025"), source: @source)
    cite!(plant("Unit 4", parent: @vogtle, reactor_type: "AP1000", capacity_mw: 1114, status: "operating", nrc_docket: "05200026"), source: @source)
    owner = link(company("Georgia Power"), "owns", unit3)
    owner.update!(ownership_pct: 45.7, description: "Co-owned.")
    owner.evidence.create!(source: @source, quote: "the project's co-owners", found_by: "human", confidence: 1)
    cite!(link(company("Southern Nuclear Operating Company, Inc. of the Southeast"), "operates", @vogtle), source: @source)
    cite!(link(company("Oglethorpe Power Corporation"), "owns", @vogtle), source: @source)
  end

  test "an owner row opens to its quote and source, with a link to the company" do
    visit plant_path(slug: @vogtle.slug)
    row = find(".nd-crow", text: "Georgia Power")
    assert_selector ".nd-share", count: 1

    row.find("button.nd-crow__line").click
    assert_text "the project's co-owners"
    assert_selector "a", text: "View Georgia Power"
  end

  test "an owner's source mark opens the sheet" do
    visit plant_path(slug: @vogtle.slug)
    find(".nd-crow", text: "Georgia Power").find("a.nd-mark").click

    assert_selector "dialog.nd-sheet[open]", text: "Vogtle"
  end

  [ [ 390, 844 ], [ 1440, 900 ] ].each do |width, height|
    test "nothing wraps on the plant page at #{width}" do
      resize_viewport(width, height)
      visit plant_path(slug: @vogtle.slug)
      first(".nd-crow button.nd-crow__line").click

      assert_empty page.evaluate_script(AUDIT)
      assert_equal 0, page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth"), "no sideways scroll"
    end
  end
end
