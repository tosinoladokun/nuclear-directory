require "test_helper"

class DesignSystemTest < ActionDispatch::IntegrationTest
  test "the design reference page renders every component" do
    get design_system_path
    assert_response :success

    %w[nd-btn nd-search nd-select nd-table nd-mono nd-overview nd-src nd-badge nd-conf].each do |component|
      assert_select ".#{component}", { minimum: 1 }, "missing #{component}"
    end
    assert_select "svg.nd-ic", minimum: 20
    # Text pages: summary, topic heading, lead, then a list (VOICE.md, #215).
    assert_select ".nd-prose section h4 + p.type-body + ul"
    # The dated source chip uses the same markup as the shared partial (#90).
    assert_select ".nd-src .nd-src__checked", minimum: 1
  end

  # #332: these were documented but no page used them, so they were deleted.
  # They come back only with the page that needs them (nd-chip did, with #558).
  REMOVED_COMPONENTS = %w[nd-az nd-banner nd-bulk nd-card nd-cards nd-empty nd-fact nd-filterbar
                          nd-graph nd-items nd-muted nd-org nd-r nd-suggest nd-tabs nd-toggle].freeze

  test "removed components stay out of the stylesheet and the design page" do
    css = Rails.root.join("app/assets/tailwind/design_system/components.css").read
    get design_system_path

    REMOVED_COMPONENTS.each do |component|
      refute_match(/\.#{component}(?![\w-])|\.#{component}(?:__|--)/, css, "#{component} is back in components.css")
      assert_select ".#{component}", { count: 0 }, "#{component} is back on /design"
    end
  end

  test "ids on the design page are unique" do
    get design_system_path

    ids = css_select("[id]").map { |node| node["id"] }
    assert_equal [], ids.tally.select { |_, n| n > 1 }.keys
  end

  test "it renders every shared page part with mock records" do
    get design_system_path

    within_parts = "#page-parts"
    %w[nd-sitebar nd-pills nd-catgrid nd-listrow nd-profile nd-factrow nd-gaps nd-sources nd-notice nd-overview].each do |part|
      assert_select "#{within_parts} .#{part}", { minimum: 1 }, "missing #{part}"
    end
    assert_select "#{within_parts} .nd-listrow", 4
  end

  test "it shows the 25 Oct system's components (#558)" do
    get design_system_path

    scope = "#system-25-oct"
    %w[nd-lines nd-line nd-chip nd-pagehead nd-idx nd-glance nd-st nd-sechead nd-toolbar nd-quiet].each do |part|
      assert_select "#{scope} .#{part}", { minimum: 1 }, "missing #{part}"
    end
    assert_select "#{scope} .nd-line--bare", 4
    assert_select "#{scope} .nd-line--bare .nd-line__end", text: "Courbevoie, France"
    assert_select "#{scope} .nd-line__name[data-fit=small]", minimum: 1
    assert_select "#{scope} .nd-chip[aria-current]", 1
    assert_select "#{scope} .nd-chips[data-controller=pill-row] .nd-chip:nth-child(5)[aria-current]", 1, "a selected chip beyond the first, scrolled into view on phones"
    assert_select "#{scope} .nd-glance__fact dt + dd", 3, "the label comes before the value in the markup"
    assert_select "#{scope} .nd-lines__head[aria-hidden=true]", 1, "the header row is visual"
    assert_select "#{scope} .nd-line__head .nd-st", 3, "the status sits right after the name"
    assert_select "#{scope} .nd-line__foot .nd-line__cap", 3, "MW is its own element"
    assert_select "#{scope} .nd-pagehead__count", "42 companies"
    assert_select "#{scope} .nd-glance__fact", 3, "a fact with no value is left out"
    assert_select "#{scope} .nd-st", 11, "six marks, and each plant row twice (beside the name; before the type on phones)"
    assert_select "#{scope} .nd-st--filled, #{scope} .nd-st--open, #{scope} .nd-st--dashed, #{scope} .nd-st--half, #{scope} .nd-st--dotted", minimum: 5
  end
end
