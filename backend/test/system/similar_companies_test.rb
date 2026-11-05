require "application_system_test_case"
require_relative "../support/directory_builders"

# Similar companies sits in a narrow column from 1024px to 1279px: its rows must stack there, not overflow (#678 follow-up).
class SimilarCompaniesSystemTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    vendor = role("reactor_vendor")
    @company = cite!(company("Alpha Reactor Works Incorporated of America", roles: [ vendor ], description: "Builds reactors.", city: "Santa Clara", state: "CA"))
    3.times do |i|
      cite!(company("Peer Company With A Rather Long Name Number #{i} Holdings", roles: [ vendor ], city: "Oak Ridge", state: "TN",
        description: "A very long description of what this peer company does in the nuclear industry across many things"))
    end
  end

  test "no row overflows its box at any width, including the narrow desktop column" do
    [ 390, 1024, 1100, 1280, 1440 ].each do |width|
      resize_viewport(width, 900)
      visit company_path(slug: @company.slug)
      assert_selector ".nd-similar .nd-line", minimum: 3
      overflow = page.evaluate_script(<<~JS)
        (() => {
          const box = document.querySelector(".nd-similar")
          return [box.scrollWidth - box.clientWidth, document.documentElement.scrollWidth - innerWidth,
            [...box.querySelectorAll("*")].filter((el) => el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflow === "visible").length]
        })()
      JS
      assert_equal 0, overflow[0], "at #{width}: the section doesn't scroll inside"
      assert_operator overflow[1], :<=, 0, "at #{width}: the page doesn't scroll sideways"
      assert_equal 0, overflow[2], "at #{width}: nothing spills out of its box"
    end
  end
end
