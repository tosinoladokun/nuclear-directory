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
  # They come back only with the page that needs them.
  REMOVED_COMPONENTS = %w[nd-az nd-banner nd-bulk nd-card nd-cards nd-chip nd-empty nd-fact nd-filterbar
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
    %w[nd-sitebar nd-pills nd-cats nd-listrow nd-profile nd-factrow nd-gaps nd-sources nd-notice nd-overview].each do |part|
      assert_select "#{within_parts} .#{part}", { minimum: 1 }, "missing #{part}"
    end
    assert_select "#{within_parts} .nd-listrow", 4
  end
end
