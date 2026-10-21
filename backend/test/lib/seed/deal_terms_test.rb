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

  test "a term's own quote without a URL is from its link's page; a URL without a quote takes the link's citation" do
    seed([ PPA.merge(quote: "200 MW from the first plant"), FRAMEWORK.merge(quote: nil) ])

    ppa, framework = %w[searchco-fusion-ppa-2025 searchco-fusion-framework-2025].map { |key| DealTerm.find_by!(external_id: key) }
    assert_equal [ [ "https://example.com/deal", "200 MW from the first plant" ] ], ppa.evidence.map { |e| [ e.source.url, e.quote ] }
    assert_equal [ [ "https://example.com/deal", "signed a PPA for 200 MW" ] ], framework.evidence.map { |e| [ e.source.url, e.quote ] },
      "never a cited page with no quote"
  end

  test "a signed deal waiting on an approval isn't counted yet; a framework or prepayment may state no MW" do
    pending = PPA.merge(key: "searchco-fusion-ppa-pending", conditions: "  NRC approval ", term_years: 20, firm_mw: 150)
    prepayment = { key: "searchco-fusion-prepay", agreement: "prepayment", status: "signed", amount_usd: 25_000_000 }
    partnership = { key: "searchco-fusion-partnership", agreement: "framework", status: "announced" }
    seed([ PPA, pending, prepayment, partnership ])

    rows = Directory::DealList.offtakes.index_by(&:key)
    assert rows["searchco-fusion-ppa-2025"].counted
    assert_equal [ false, "NRC approval", 20, 150 ], rows["searchco-fusion-ppa-pending"].then { |r| [ r.counted, r.conditions, r.term_years, r.firm_mw.to_i ] }
    assert_equal [ false, false ], [ rows["searchco-fusion-prepay"].counted, rows["searchco-fusion-partnership"].counted ]
    assert_nil rows["searchco-fusion-partnership"].capacity_mw, "not stated stays blank"

    error = assert_raises(Seed::OrganizationLoader::Error) { seed([ PPA.except(:capacity_mw).merge(key: "searchco-no-size") ]) }
    assert_match "needs capacity_mw or amount_usd", error.message, "a deal that can be counted states its size"
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

  test "a term's own quote on its link's page has its confidence checked like any other" do
    error = assert_raises(Seed::OrganizationLoader::Error) { seed([ PPA.merge(quote: "signed a PPA for 200 MW", confidence: 1.5) ]) }
    assert_match "confidence 1.5 isn't a number from 0 to 1", error.message
  end

  test "a condition met since is cleared by giving it as null; leaving it out keeps it" do
    seed([ PPA.merge(conditions: "NRC approval") ])
    assert_not DealTerm.sole.counted?

    seed([ PPA ])
    assert_equal "NRC approval", DealTerm.sole.conditions, "left out: nothing to say"

    seed([ PPA.merge(conditions: nil) ])
    assert_nil DealTerm.sole.conditions
    assert DealTerm.sole.counted?
  end
end
