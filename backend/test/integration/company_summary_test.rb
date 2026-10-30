require "test_helper"
require_relative "../support/directory_builders"

# Thin pages (Outcome 30 Nov): a company with no written description gets one factual sentence from its published facts
# (role, place, signed deals, sites). No adjectives; nothing when there is nothing to say; a written description wins.
class CompanySummaryTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  test "role, place, deals and sites become one plain sentence under the name and in the meta description" do
    kairos = cite!(company("Kairos Power", roles: [ role("reactor_vendor") ], city: "Alameda", state: "CA"))
    cite!(link(cite!(company("Google", roles: [ role("data_center_offtaker") ])), "offtake_with", kairos)).update!(description: "Signed: 500 MW.")
    cite!(link(kairos, "owns", cite!(plant("Hermes", facility_type: "research_reactor", city: "Oak Ridge", state: "TN"))))

    get company_path(slug: kairos.slug)

    sentence = "Kairos Power is a reactor developer in Alameda, CA, with 1 deal and 1 site."
    assert_select ".nd-pagehead__about", sentence
    assert_match(/\A#{Regexp.escape(sentence)}/, css_select("meta[name='description']").first["content"])
  end

  test "an enrichment company takes 'an', and a company with only a role is still one sentence" do
    centrus = cite!(company("Centrus Energy", roles: [ role("enrichment") ]))
    get company_path(slug: centrus.slug)
    assert_select ".nd-pagehead__about", "Centrus Energy is an enrichment company."
  end

  test "a written description is shown as it is, and a company with nothing published says nothing" do
    written = cite!(company("Written Co", description: "Makes valves.", city: "Reston", state: "VA"))
    get company_path(slug: written.slug)
    assert_select ".nd-pagehead__about", "Makes valves."

    bare = cite!(company("Bare Co"))
    get company_path(slug: bare.slug)
    assert_select ".nd-pagehead__about", 0
  end
end
