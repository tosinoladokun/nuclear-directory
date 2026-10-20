require "test_helper"

# The line under a page's key facts names a fact only when one of the
# record's own quotes states the value shown (#407).
class Directory::QuoteBackingTest < ActiveSupport::TestCase
  Backing = Directory::QuoteBacking
  VERIFIED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/quotes", source_kind: "nrc_reactor_list", domain: "www.nrc.gov")
  end

  def quote(record, text) = Evidence.create!(subject: record, source: @source, quote: text, found_by: "crawler")

  test "a docket or legal name counts as whole words, case and spacing aside" do
    assert Backing.contains?([ "Docket No. 05000254, Quad Cities" ], "05000254")
    assert_not Backing.contains?([ "Docket No. 050002541" ], "05000254"), "part of a longer number isn't it"
    assert Backing.contains?([ "BWXT NUCLEAR  ENERGY, INC. received" ], "BWXT Nuclear Energy, Inc.")
    assert_not Backing.contains?([ "Richlands, VA" ], "Richland")
    assert_not Backing.contains?([ "anything" ], nil)
  end

  test "a docket in NRC's short forms counts too, but not another number" do
    assert Backing.docket?([ "Docket No. 50-254" ], "05000254")
    assert Backing.docket?([ "Docket 050-00254 (Quad Cities)" ], "05000254")
    assert Backing.docket?([ "Docket 50-7513" ], "05007513")
    assert_not Backing.docket?([ "Docket 50-2541" ], "05000254")
    assert_not Backing.docket?([ "Docket 150-254" ], "05000254")
    assert_not Backing.docket?([ "Docket 70-254" ], "05000254"), "another kind of license"
  end

  test "a state in AP style counts; dashes of any kind are one" do
    assert Backing.place?([ "Oak Ridge, Tenn." ], city: "Oak Ridge", state: "TN")
    assert Backing.place?([ "DAVIDSON, N.C. (BUSINESS WIRE)" ], city: "Davidson", state: "NC")
    assert_not Backing.place?([ "Morgantown, W.Va." ], city: "Morgantown", state: "VA"), "W.Va. isn't Va."
    assert_not Backing.place?([ "Morgantown, West Virginia" ], city: "Morgantown", state: "VA"), "West Virginia isn't Virginia"
    assert_not Backing.place?([ "MORGANTOWN, W.VA." ], city: "Morgantown", state: "VA"), "nor is W.VA."
    assert Backing.place?([ "Morgantown, West Virginia, and Bristol, Virginia" ], city: "Bristol", state: "VA"), "another mention of Virginia still counts"
    assert Backing.place?([ "Morgantown, West Virginia" ], city: "Morgantown", state: "WV")
    assert Backing.contains?([ "Northern States Power Company - Minnesota" ], "Northern States Power Company – Minnesota")
  end

  test "a place: the city and the state, as its code or its full name, in one quote" do
    assert Backing.place?([ "Cordova, IL 61242" ], city: "Cordova", state: "IL")
    assert Backing.place?([ "located in Cordova, Illinois" ], city: "Cordova", state: "IL"), "the state by its full name"
    assert Backing.place?([ "Cordova, IL" ], city: "Cordova", state: "Illinois"), "a stored full name matches the code"
    assert_not Backing.place?([ "Cordova", "Illinois" ], city: "Cordova", state: "IL"), "split across quotes"
    assert_not Backing.place?([ "Cordova, il" ], city: "Cordova", state: "IL"), "a code only in capitals"
    assert_not Backing.place?([ "built in Indiana" ], city: nil, state: "OR"), "\"in\" isn't Indiana and Oregon isn't there"
    assert Backing.place?([ "a plant in Oregon" ], city: nil, state: "OR"), "only what's stored needs stating"
    assert_not Backing.place?([ "anything" ], city: nil, state: nil)
  end

  test "a company names its headquarters and legal name only when its own quotes state them" do
    company = Organization.create!(name: "Imaginary Fission", legal_name: "Imaginary Fission Holdings, Inc.", hq_city: "Bellevue", hq_state: "WA", **VERIFIED)
    quote(company, "Imaginary Fission is based in Bellevue, Washington.")
    assert_equal [ :headquarters ], CompanyProfile.new(company).quoted_facts

    quote(company, "IMAGINARY FISSION HOLDINGS, INC. filed")
    assert_equal [ :headquarters, :legal_name ], CompanyProfile.new(company.reload).quoted_facts

    company.update!(hq_city: "Seattle")
    assert_equal [ :legal_name ], CompanyProfile.new(company.reload).quoted_facts, "an edit no quote states stops being named"
  end

  test "a plant names its docket and location only when the site's own quotes state them" do
    site = Facility.create!(name: "Quad Cities", nrc_docket: "05000254", city: "Cordova", state: "IL", **VERIFIED)
    quote(site, "Quad Cities 1, docket 05000254")
    assert_equal [ :docket ], PlantProfile.new(site).quoted_facts

    quote(site, "Cordova, Illinois")
    assert_equal [ :docket, :location ], PlantProfile.new(site.reload).quoted_facts
  end

  test "a pending site's facts aren't shown, so none is named" do
    site = Facility.create!(name: "Pending Site", nrc_docket: "05000999", verification_status: "pending")
    quote(site, "docket 05000999")

    assert_empty PlantProfile.new(site).quoted_facts
  end
end
