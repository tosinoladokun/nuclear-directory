require "application_system_test_case"
require_relative "../support/directory_builders"

# The company page (#556): rows open in place, a source mark opens its sources in the sheet,
# the quiet line opens the numbered list and the citation, and nothing wraps at 390 or 1440.
class CompanyPageSystemTest < ApplicationSystemTestCase
  include DirectoryBuilders

  AUDIT = File.readlines(File.expand_path("../support/no_wrap_audit.js", __dir__)).reject { |line| line.start_with?("//") }.join

  setup do
    @source = Source.create!(url: "https://kairospower.com/news/google", title: "Google and Kairos Power partner", source_kind: "web_page", published_on: Date.new(2024, 10, 14))
    @company = cite!(company("X-energy Reactor Company", city: "Rockville", state: "MD", roles: [ role("reactor_vendor"), role("project_developer") ],
      techs: [ technology("smr", "Small modular reactor") ], aliases: [ "X Energy", "Xe" ], website: "https://x-energy.com", legal_name: "X Energy, LLC",
      description: "Develops high-temperature gas-cooled reactors and TRISO fuel for advanced plants."), source: @source)
    offtaker = role("data_center_offtaker")
    deal = link(cite!(company("Amazon Web Services", roles: [ offtaker ]), source: @source), "offtake_with", @company)
    deal.update!(description: "A framework for 5 GW of SMR capacity by 2039.")
    deal.evidence.create!(source: @source, quote: "They signed a framework", found_by: "human", confidence: 1)
    plant = cite!(plant("Long Mott Generating Station", facility_type: "power_reactor", status: "planned", city: "Seadrift", state: "TX"), source: @source)
    link(@company, "owns", plant).evidence.create!(source: @source, found_by: "human", confidence: 1)
  end

  test "a deal row opens and closes in place" do
    visit company_path(slug: @company.slug)
    row = find(".nd-crow", text: "Amazon Web Services")
    assert_selector ".nd-crow__more", visible: :hidden, count: 1

    row.find("button.nd-crow__line").click
    assert_selector "button.nd-crow__line[aria-expanded=true]"
    assert_text "A framework for 5 GW of SMR capacity by 2039."
    assert_text "They signed a framework"

    row.find("button.nd-crow__line").click
    assert_selector "button.nd-crow__line[aria-expanded=false]"
    assert_no_text "They signed a framework"
  end

  test "a source mark opens that row's sources in the sheet at any width" do
    visit company_path(slug: @company.slug)
    first(".nd-crow a.nd-mark").click

    assert_selector "dialog.nd-sheet[open]"
    assert_selector "dialog.nd-sheet[open]", text: "Google and Kairos Power partner"
    click_button "Close source details"
    assert_no_selector "dialog.nd-sheet[open]"
  end

  test "the quiet line opens the numbered sources and the citation in place, and Copy says Copied" do
    visit company_path(slug: @company.slug)
    assert_selector "ol.nd-sources", visible: :hidden

    find("button[data-panel=sources]").click
    assert_selector "ol.nd-sources li#source-1", text: "Google and Kairos Power partner"
    click_button "Cite this page"
    assert_selector "#cite .nd-cite", text: /Nuclear Directory\. “X-energy Reactor Company\.”/
    within("#cite") { click_button "Copy" }
    assert_selector "#cite button", text: "Copied"
    assert_selector "#cite button", text: "Copy", exact_text: true, wait: 5
  end

  [ [ 390, 844 ], [ 1440, 900 ] ].each do |width, height|
    test "nothing wraps on the company page at #{width}" do
      resize_viewport(width, height)
      visit company_path(slug: @company.slug)
      first(".nd-crow button.nd-crow__line").click

      assert_empty page.evaluate_script(AUDIT)
      assert_equal 0, page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth"), "no sideways scroll"
    end
  end
end
