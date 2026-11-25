require "test_helper"
require_relative "../support/directory_builders"

# Homepage B's charts (#909): every number from published, sourced facts, as the buckets count them.
class HomeChartsTest < ActiveSupport::TestCase
  include DirectoryBuilders

  Request = Data.define(:remote_ip, :user_agent)

  def charts = HomeCharts.new
  def source(host) = Source.create!(url: "https://#{host}/page-#{SecureRandom.hex(3)}", source_kind: "web_page")

  test "fuel: each step's count and its most connected companies, unsourced roles left out, with the sources' domains" do
    fuel = role("fuel")
    enrichment = role("enrichment", parent: fuel)
    role("mining", parent: fuel)
    role("conversion", parent: fuel)
    role("fabrication", parent: fuel)
    centrus = cite!(company("Centrus Energy", roles: [ enrichment ]), source: source("nrc.gov"))
    cite!(company("Urenco", roles: [ enrichment ]), source: source("urenco.com"))
    company("Unsourced Enrichment", roles: [ enrichment ])
    cite!(link(centrus, "supplies", cite!(company("Buyer Co"))))

    data = charts.fuel
    step = data[:steps].find { |row| row[:step] == "enrichment" }
    assert_equal 2, step[:count]
    assert_equal [ "Centrus Energy", "Urenco" ], step[:companies].map { |row| row[:name] }, "most connected first"
    assert_equal [ 0, 0, 0 ], data[:steps].reject { |row| row[:step] == "enrichment" }.map { |row| row[:count] }
    assert_equal({ domains: %w[nrc.gov urenco.com], more: false }, data[:sources])
  end

  test "operators: operating power plants (sites) per operator; a unit counts its site once; ended links don't count" do
    plant = cite!(plant("Plant Vogtle", status: "operating"))
    2.times { |i| cite!(Facility.create!(name: "Vogtle #{i + 3}", parent: plant, facility_type: "power_reactor", status: "operating", **verification(true))) }
    other = cite!(plant("Plant Hatch", facility_type: "power_reactor", status: "operating"))
    southern = cite!(company("Southern Nuclear"))
    plant.children.each { |unit| cite!(link(southern, "operates", unit), source: source("nrc.gov")) }
    cite!(link(southern, "operates", other), source: source("nrc.gov"))
    old = cite!(company("Old Operator"))
    cite!(link(old, "operates", other)).update!(ended_on: Date.new(2020, 1, 1))

    data = charts.operators
    assert_equal [ [ "Southern Nuclear", 2 ] ], data[:rows].map { |row| [ row[:name], row[:count] ] }
    assert_equal [ "nrc.gov" ], data[:sources][:domains]
  end

  test "buyers: signed power deals per buyer; a framework deal doesn't count" do
    offtaker = role("data_center_offtaker")
    amazon = cite!(company("Amazon", roles: [ offtaker ]))
    kairos = cite!(company("Kairos Power"))
    x = cite!(company("X-energy"))
    # Two signed agreements with one seller are two deals; a link without terms counts when its words say "Signed".
    two = cite!(link(amazon, "offtake_with", kairos), source: source("aboutamazon.com"))
    2.times { |i| cite!(DealTerm.create!(link: two, term_type: "offtake", agreement: "ppa", status: "signed", capacity_mw: 100 + i, **verification(true))) }
    cite!(link(amazon, "offtake_with", x).tap { |deal| deal.update!(description: "Signed a power purchase agreement") }, source: source("x-energy.com"))
    google = cite!(company("Google", roles: [ offtaker ]))
    framework = cite!(link(google, "offtake_with", kairos))
    DealTerm.create!(link: framework, term_type: "offtake", agreement: "framework", **verification(true))
    pending = cite!(link(google, "offtake_with", x))
    DealTerm.create!(link: pending, term_type: "offtake", agreement: "ppa", status: "signed", capacity_mw: 50, conditions: "NRC approval", **verification(true))
    cite!(link(google, "offtake_with", cite!(company("Elementl")))) # no terms, no "Signed": not counted

    data = charts.buyers
    assert_equal [ [ "Amazon", 3 ] ], data[:rows].map { |row| [ row[:name], row[:count] ] }, "frameworks, conditional and unsigned deals don't count"
    assert_equal %w[aboutamazon.com example.org x-energy.com], data[:sources][:domains].sort, "the links' and the counted terms' sources"
  end

  test "owners: the plant with the most owners whose stated shares add up to 100%, and who runs it" do
    vogtle = cite!(plant("Plant Vogtle"))
    { "Georgia Power" => 45.7, "Oglethorpe Power" => 30.0, "MEAG Power" => 22.7, "Dalton Utilities" => 1.6 }.each do |name, pct|
      cite!(link(cite!(company(name)), "owns", vogtle), source: source("georgiapower.com")).update!(ownership_pct: pct)
    end
    cite!(link(cite!(company("Southern Nuclear")), "operates", vogtle), source: source("nrc.gov"))
    partial = cite!(plant("Half Known"))
    cite!(link(cite!(company("Owner A")), "owns", partial)).update!(ownership_pct: 50)
    cite!(link(cite!(company("Owner B")), "owns", partial)) # no share stated: the plant can't be shown

    data = charts.owners
    assert_equal "Plant Vogtle", data[:plant]
    assert_equal [ [ "Georgia Power", 45.7 ], [ "Oglethorpe Power", 30.0 ], [ "MEAG Power", 22.7 ], [ "Dalton Utilities", 1.6 ] ],
      data[:owners].map { |row| [ row[:name], row[:pct] ] }
    assert_equal "Southern Nuclear", data[:operator][:name]
    assert_equal %w[georgiapower.com nrc.gov], data[:sources][:domains], "the operator's source joins the card's"
  end

  test "owners: an operator that also owns a share still runs it (#920 review)" do
    plant = cite!(plant("North Anna Power Station"))
    dominion = cite!(company("Dominion Energy"))
    cite!(link(dominion, "owns", plant)).update!(ownership_pct: 88.4)
    cite!(link(cite!(company("Old Dominion Electric Cooperative")), "owns", plant)).update!(ownership_pct: 11.6)
    cite!(link(dominion, "operates", plant))

    assert_equal "Dominion Energy", charts.owners[:operator][:name]
  end

  test "fuel: a company in a step through a sub-role brings its source too (#920 review)" do
    fuel = role("fuel")
    enrichment = role("enrichment", parent: fuel)
    %w[mining conversion fabrication].each { |key| role(key, parent: fuel) }
    laser = role("laser_enrichment", parent: enrichment)
    cite!(company("Global Laser Enrichment", roles: [ laser ]), source: source("gle-us.com"))

    data = charts.fuel
    assert_equal [ "Global Laser Enrichment" ], data[:steps].find { |row| row[:step] == "enrichment" }[:companies].map { |row| row[:name] }
    assert_equal [ "gle-us.com" ], data[:sources][:domains]
  end

  test "newest: sourced facts only (#920 review)" do
    cite!(company("Kairos Power"), source: source("kairospower.com"))
    company("Unsourced Co")

    assert charts.newest.all? { |row| row[:domain].present? }
    assert_not charts.newest.any? { |row| row[:title].include?("Unsourced Co") }
  end

  test "categories: each category with companies, largest first, and the companies in all" do
    cite!(company("Kairos Power", roles: [ role("reactor_vendor") ]))
    data = charts.categories
    assert_equal [ [ "reactor-developers", 1 ] ], data[:rows].map { |row| [ row[:key], row[:count] ] }
    assert_operator data[:total], :>=, 1
  end

  test "a visitor's set changes from one day to the next, and stays put within a day" do
    request = Request.new(remote_ip: "203.0.113.9", user_agent: "Safari")
    day = Date.new(2026, 12, 1)
    sets = (0..6).map { |n| HomeCharts.set_for(request, day: day + n) }
    sets.each_cons(2) { |a, b| assert_not_equal a, b }
    assert_equal HomeCharts.set_for(request, day:), HomeCharts.set_for(request, day:)
    assert HomeCharts::SETS.all? { |set| set.uniq.size == 3 }, "no chart twice on one screen"
  end

  test "a set with an empty chart gives way to the next; with none whole, nothing" do
    request = Request.new(remote_ip: "203.0.113.9", user_agent: "Safari")
    assert_nil HomeCharts.cards_for(request), "an empty directory has no whole set"

    with_data = { fuel: { steps: [ { companies: [ 1 ] } ] }, newest: [ 1 ], categories: { rows: [ 1 ] }, operators: { rows: [] }, buyers: { rows: [ 1 ] }, owners: {} }
    assert_equal %i[fuel newest categories], HomeCharts.cards_for(request, data: with_data.method(:fetch)).map(&:first),
      "operators has nothing, so its set gives way, whichever set the visitor drew"
  end
end
