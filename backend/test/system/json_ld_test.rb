require "application_system_test_case"
require_relative "../support/directory_builders"

# Turbo keeps the head's scripts from earlier pages; the JSON-LD sits in the
# body, so walking between profiles leaves only the current page's graph.
class JsonLdTest < ApplicationSystemTestCase
  include DirectoryBuilders

  test "visiting a company and then its plant leaves only the plant's graph in the document" do
    owner = cite!(company("Graph Owner Power"))
    site = cite!(plant("Graph Station", facility_type: "power_reactor", status: "operating", city: "Lusby", state: "MD"))
    cite!(link(owner, "owns", site))

    visit company_path(slug: owner.slug)
    assert_equal [ "Graph Owner Power" ], graph_names

    click_link "Graph Station", match: :first
    assert_selector "h1", text: "Graph Station", wait: 15
    assert_equal [ "Graph Station" ], graph_names, "one graph, the current page's, after a Turbo visit"
  end

  def graph_names
    page.evaluate_script("[...document.querySelectorAll('script[type=\"application/ld+json\"]')].map((s) => JSON.parse(s.textContent)['@graph'][1].name)")
  end
end
