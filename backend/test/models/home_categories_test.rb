require "test_helper"
require_relative "../support/directory_builders"

# Which names each home page card shows (#362; Tosin, 17 Oct).
class HomeCategoriesTest < ActiveSupport::TestCase
  include DirectoryBuilders

  def card(key) = HomeCategories.cards.find { |c| c.category.key == key }
  def names(key) = card(key).records.map(&:name)

  setup do
    @vendor = role("reactor_vendor")
    @plant = cite!(plant("Plant Vogtle", facility_type: "power_reactor", status: "operating"))
  end

  test "the three companies with the most sourced links, ties by name" do
    big = cite!(company("Westinghouse", roles: [ @vendor ]))
    %w[Alpha Beta Gamma].each { |name| cite!(link(big, "supplies", cite!(company(name)))) }
    mid = cite!(company("Kairos Power", roles: [ @vendor ]))
    cite!(link(mid, "owns", @plant))
    cite!(company("Oklo", roles: [ @vendor ]))
    cite!(company("NuScale Power", roles: [ @vendor ]))

    assert_equal [ "Westinghouse", "Kairos Power", "NuScale Power" ], names("reactor-developers"), "Oklo ties NuScale on 0 and loses on name"
    assert_equal 4, card("reactor-developers").count
    assert card("reactor-developers").more?
  end

  test "a company shows on one card only: a later card skips it and the next one fills the spot, counts unchanged" do
    fuel = role("fuel")
    kairos = cite!(company("Kairos Power", roles: [ @vendor, fuel ]))
    cite!(link(kairos, "owns", @plant))
    cite!(company("Oklo", roles: [ @vendor ]))
    %w[Centrus Orano Urenco Cameco].each { |name| cite!(company(name, roles: [ fuel ])) }

    assert_includes names("reactor-developers"), "Kairos Power"
    assert_not_includes names("fuel"), "Kairos Power", "shown under Developers, an earlier card"
    assert_equal [ "Cameco", "Centrus", "Orano" ], names("fuel"), "the next ones by links, then name, fill the spots"
    assert_equal 5, card("fuel").count, "the count is still the category's real total"
    assert card("fuel").more?
  end

  test "no company name repeats across the cards, and a card with none left keeps its count" do
    fuel = role("fuel")
    %w[Alpha Beta].each { |name| cite!(company(name, roles: [ @vendor, fuel ])) }
    shown = HomeCategories.cards.reject { |c| c.category.plants }.flat_map { |c| c.records.map(&:id) }

    assert_equal shown.uniq, shown
    assert_empty card("fuel").records, "both fuel companies already show under Developers"
    assert_equal 2, card("fuel").count
  end

  test "unsourced or unpublished links don't count" do
    quiet = cite!(company("Quiet Co", roles: [ @vendor ]))
    link(quiet, "owns", @plant) # no source
    3.times { |i| link(quiet, "supplies", cite!(company("Hidden #{i}", verified: false))) }
    loud = cite!(company("Loud Co", roles: [ @vendor ]))
    cite!(link(loud, "owns", @plant))

    assert_equal [ "Loud Co", "Quiet Co" ], names("reactor-developers")
  end

  test "investors rank by how many companies they fund, not by their links" do
    a, b, c = %w[A B C].map { |name| cite!(company("Startup #{name}")) }
    big = cite!(company("Big Fund"))
    cite!(link(big, "funds", a), link(big, "invests_in", a), link(big, "supplies", b), link(big, "supplies", c)) # 4 links, funds 1
    spread = cite!(company("Spread Ventures"))
    cite!(link(spread, "invests_in", a), link(spread, "invests_in", b)) # 2 links, funds 2

    assert_equal [ "Spread Ventures", "Big Fund" ], names("investors")
  end

  test "Plants and sites is the last card, ranked by sourced links" do
    cite!(company("Kairos Power", roles: [ @vendor ]))
    quiet = cite!(plant("Quiet Plant"))
    busy = cite!(plant("Busy Plant"))
    2.times { |i| cite!(link(cite!(company("Owner #{i}")), "owns", busy)) }

    assert_equal "plants", HomeCategories.cards.last.category.key
    assert_equal [ "Busy Plant", "Plant Vogtle", "Quiet Plant" ], names("plants")
    assert_not_includes HomeCategories.cards.map { |c| c.category.key }, "components", "an empty bucket has no card"
    assert_equal "Quiet Plant", quiet.name
  end

  test "only records with a public page" do
    cite!(company("Pending Co", roles: [ @vendor ], verified: false))
    plant("Hidden Site", verified: false)
    cite!(company("Kairos Power", roles: [ @vendor ]))

    assert_equal [ "Kairos Power" ], names("reactor-developers")
    assert_not_includes names("plants"), "Hidden Site"
    assert_not card("reactor-developers").more?
  end
end
