require "test_helper"

# A deal's terms in the seed (#256): each agreement under its link, as data
# the first data piece (#255) and the export (#254) read.
class Seed::DealTermsTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
  end

  teardown { FileUtils.remove_entry(@dir) }

  def write_file(slug, doc) = File.write(File.join(@dir, "#{slug}.yml"), doc.deep_stringify_keys.to_yaml)

  def org(name, website:, **extra)
    { name:, aliases: [], website:, hq: nil, country_code: "US", status: "active",
      roles: [], technologies: [], relationships: [], facilities: [], notes: "" }.merge(extra)
  end

  def deal(terms, **extra)
    { type: "offtake_with", to: "Imaginary Fusion", description: "Signed PPA for 200 MW and a framework for more.",
      source_url: "https://example.com/deal", quote: "signed a PPA for 200 MW", confidence: 1.0, published: "2025-06-30", terms: }.merge(extra)
  end

  def load! = Seed::OrganizationLoader.new(@dir).load!

  def seed(terms)
    write_file("imaginary-fusion", org("Imaginary Fusion", website: "https://imaginaryfusion.example"))
    write_file("searchco", org("SearchCo", website: "https://searchco.example", relationships: [ deal(terms) ]))
    load!
  end

  PPA = { key: "searchco-fusion-ppa-2025", agreement: "ppa", status: "signed", capacity_mw: 200, signed_on: "2025-06-30" }.freeze
  FRAMEWORK = { key: "searchco-fusion-framework-2025", agreement: "framework", status: "announced", capacity_mw: 1000,
    source_url: "https://example.com/framework", quote: "a framework for up to 1 GW" }.freeze

  test "each agreement under a deal is a term with its own MW, dates, form and status, cited from the link's quote or its own" do
    seed([ PPA, FRAMEWORK ])

    link = Relationship.find_by!(relationship_type: "offtake_with")
    ppa, framework = DealTerm.where(link:).order(:external_id).to_a.values_at(1, 0)
    assert_equal [ "offtake", "ppa", "signed", 200, Date.new(2025, 6, 30) ],
      [ ppa.term_type, ppa.agreement, ppa.status, ppa.capacity_mw.to_i, ppa.signed_on ]
    assert ppa.verified?
    assert_equal [ "signed a PPA for 200 MW" ], ppa.evidence.map(&:quote), "the link's quote, when the term gives none"
    assert_equal [ "a framework for up to 1 GW" ], framework.evidence.map(&:quote)
    assert_equal [ true, false ], [ ppa.counted?, framework.counted? ]
  end

  test "a re-seed updates a term by its key instead of adding another" do
    seed([ PPA ])
    loader = seed([ PPA.merge(capacity_mw: 210) ])

    assert_equal 1, DealTerm.count
    assert_equal 210, DealTerm.sole.capacity_mw.to_i
    assert_equal({ created: 0, changed: 1, unchanged: 0 }, loader.results[:deal_term])
  end

  test "a term without a key, or with an unknown form of agreement, fails the load and writes nothing" do
    error = assert_raises(Seed::OrganizationLoader::Error) { seed([ PPA.except(:key) ]) }
    assert_match "needs a key", error.message

    error = assert_raises(Seed::OrganizationLoader::Error) { seed([ PPA.merge(agreement: "handshake") ]) }
    assert_match(/agreement/i, error.message)
    assert_equal 0, DealTerm.count
  end

  test "the deal list: one row per published agreement, buyer and seller, counted only when signed" do
    seed([ PPA, FRAMEWORK ])

    rows = Directory::DealList.offtakes
    assert_equal %w[searchco-fusion-ppa-2025 searchco-fusion-framework-2025], rows.map(&:key), "signed first, newest first"
    assert_equal [ "SearchCo", "Imaginary Fusion" ], [ rows.first.buyer.name, rows.first.seller.name ]
    assert_equal [ true, false ], rows.map(&:counted)
    assert_equal [ "https://example.com/framework" ], rows.last.sources.map(&:url)

    Relationship.find_by!(relationship_type: "offtake_with").unpublish!(by: "human:tosin", reason: "Test")
    assert_empty Directory::DealList.offtakes, "a term is public only with its link"
  end
end
