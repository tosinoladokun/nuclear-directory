require "test_helper"

class DirectoryHelperTest < ActionView::TestCase
  # Stands in for PlantProfile: only what plant_preview reads.
  Profile = Struct.new(:name, :status, :facility_type, :city, :state, :units, :capacity_mw, :owners, :operators, keyword_init: true) do
    def current_companies_for(type) = { "owns" => owners, "operates" => operators }.fetch(type).to_a.map { |name| Struct.new(:name).new(name) }
  end

  Unit = Struct.new(:status)
  def units(*statuses) = statuses.map { |status| Unit.new(status) }

  def profile(**overrides)
    Profile.new(name: "Plant Vogtle", status: "operating", facility_type: "power_reactor", city: "Waynesboro", state: "GA",
      units: units(*Array.new(4, "operating")), capacity_mw: BigDecimal("4536"), owners: [ "Georgia Power" ], operators: [ "Southern Nuclear" ], **overrides)
  end

  test "a plant's preview says what it is, where, how big, and who owns and runs it (#246)" do
    assert_equal "Plant Vogtle: Operating power plant in Waynesboro, Georgia. 4 units, 4,536 MW. Owned by Georgia Power; operated by Southern Nuclear.",
      plant_preview(profile)
  end

  test "a plant that's not operating says so after the place (#296)" do
    palisades = profile(name: "Palisades", status: "not_operating", city: "Covert", state: "MI", units: units("not_operating"), capacity_mw: nil,
      owners: [ "Holtec" ], operators: [ "Holtec" ])

    assert_equal "Palisades: Power plant in Covert, Michigan, not operating. 1 unit. Owned by Holtec; operated by Holtec.", plant_preview(palisades)
    assert_equal "Palisades: Not operating.", plant_preview(profile(name: "Palisades", status: "not_operating", facility_type: nil, city: nil, state: nil,
      units: [], capacity_mw: nil, owners: [], operators: []))
  end

  test "a plant's preview stays under 160 characters: a long owner list becomes the first and a count" do
    owners = [ "Georgia Power", "Oglethorpe Power", "MEAG Power", "Dalton Utilities" ]
    line = plant_preview(profile(owners:))

    assert_equal "Plant Vogtle: Operating power plant in Waynesboro, Georgia. 4 units, 4,536 MW. " \
      "Owned by Georgia Power and 3 others; operated by Southern Nuclear.", line
    assert_operator line.length, :<=, 160
  end

  test "a plant's owners are listed as the site writes lists, without a serial comma" do
    line = plant_preview(profile(name: "Vogtle", status: nil, facility_type: nil, city: nil, state: nil, units: [], capacity_mw: nil,
      owners: [ "Dalton Utilities", "Georgia Power", "MEAG Power" ], operators: []))

    assert_equal "Vogtle: Owned by Dalton Utilities, Georgia Power and MEAG Power.", line
  end

  test "a plant's preview leaves out what isn't known, and never says nothing" do
    assert_equal "Hermes: Test reactor in Oak Ridge, Tennessee. Operated by Kairos Power.",
      plant_preview(profile(name: "Hermes", status: nil, facility_type: "research_reactor", city: "Oak Ridge", state: "TN",
        units: [], capacity_mw: nil, owners: [], operators: [ "Kairos Power" ]))
    assert_equal "Blank Site", plant_preview(profile(name: "Blank Site", status: nil, facility_type: nil, city: nil, state: nil,
      units: [], capacity_mw: nil, owners: [], operators: []))
    assert_equal "Gone Plant: In Somewhere, Texas. 1 unit.", plant_preview(profile(name: "Gone Plant", status: nil, facility_type: nil,
      city: "Somewhere", state: "TX", units: units(nil), capacity_mw: nil, owners: [], operators: []))
  end

  test "units are counted by status, operating first; the plant's own status isn't repeated (PM, 16 Oct)" do
    assert_equal "4 operating units", units_summary(%w[operating operating operating operating])
    assert_equal "4 units", units_summary(%w[operating operating operating operating], shown_status: "operating")
    assert_equal "2 operating units, 1 being decommissioned", units_summary(%w[decommissioning operating operating], shown_status: "operating")
    assert_equal "1 unit, not operating", units_summary(%w[not_operating])
    assert_equal "1 unit", units_summary(%w[not_operating], shown_status: "not_operating")
    assert_equal "3 units: 2 shut down, 1 being decommissioned", units_summary(%w[shut_down decommissioning shut_down])
    assert_equal "1 operating reactor, 1 not stated", units_summary([ "operating", nil ], noun: "reactor")
    assert_equal "2 units", units_summary([ nil, "" ])
    assert_nil units_summary([])

    dresden = profile(name: "Dresden", city: "Morris", state: "IL", units: units("operating", "operating", "decommissioning"),
      capacity_mw: BigDecimal("1845"), owners: [], operators: [ "Constellation" ])
    assert_equal "Dresden: Operating power plant in Morris, Illinois. 2 operating units, 1 being decommissioned, 1,845 MW. " \
      "Operated by Constellation.", plant_preview(dresden)
  end

  test "a plant's preview drops the size, then owners, before it would run long" do
    owners = [ "A Very Long Utility Company Name Incorporated", "Another" ]
    operators = [ "An Exceptionally Long Operating Company Name, LLC" ]
    line = plant_preview(profile(name: "Some Generating Station With A Long Name", owners:, operators:))

    assert_operator line.length, :<=, 160
    assert_match "Operated by An Exceptionally Long Operating Company Name, LLC", line, "the operator outlasts the owners"
    assert_no_match "MW", line
  end
  test "a site's icon follows its type, a power plant's its reactors (Design, #281)" do
    assert_equal "site-pwr", site_icon_name("power_reactor", reactor_types: [ "PWR", nil ])
    assert_equal "site-pwr", site_icon_name("power_reactor", reactor_types: [ "AP1000" ])
    assert_equal "site-bwr", site_icon_name("power_reactor", reactor_types: [ "BWR" ])
    assert_equal "site-plant", site_icon_name("power_reactor", reactor_types: [ "BWR", "PWR" ]), "mixed types: the generic plant"
    assert_equal "site-advanced", site_icon_name("power_reactor", reactor_types: [ "Natrium" ])
    assert_equal "site-plant", site_icon_name("power_reactor")
    assert_equal "site-advanced", site_icon_name("power_reactor", status: "planned"), "Long Mott, before a type is stated"
    assert_equal "site-advanced", site_icon_name("power_reactor", reactor_types: [ nil ], status: "under_construction"), "Kemmerer, Hermes 2"
    assert_equal "site-pwr", site_icon_name("power_reactor", reactor_types: [ "AP1000" ], status: "under_construction")
    assert_equal "site-waste", site_icon_name("power_reactor", reactor_types: [ "PWR" ], status: "decommissioning")
    assert_equal "site-research", site_icon_name("research_reactor")
    assert_equal "site-fusion", site_icon_name("fusion_facility")
    assert_equal "site-mine", site_icon_name("mill")
    assert_equal "site-enrichment", site_icon_name("enrichment")
    assert_equal "site-fuel", site_icon_name("fuel_facility")
    assert_equal "site-plant", site_icon_name(nil)
  end

  test "a list splits before its last item, never at a comma inside a name or link" do
    links = safe_join([ link_to("Georgia Power", "/a"), ", ", link_to("Southern Nuclear Operating Co., Inc.", "/b") ])
    head, last = split_last_item(links)
    assert_equal '<a href="/a" title="Georgia Power" data-truncate="">Georgia Power</a>, ', head, "a name before the last carries its full name, in case it's cut"
    assert_equal '<a href="/b">Southern Nuclear Operating Co., Inc.</a>', last
    assert head.html_safe? && last.html_safe?

    assert_nil split_last_item("Fission, <b>SMR</b>"), "plain text is never split (nor trusted as HTML)"
    assert_nil split_last_item("Baton Rouge Metropolitan Area, LA"), "a place with a comma isn't a list"

    assert_nil split_last_item(link_to("Southern Nuclear Operating Co., Inc.", "/b")), "one name with a comma isn't a list"
    assert_nil split_last_item("Bernhard Capital Partners Management")
  end

  test "relationship verbs read left to right in visitors' words" do
    assert_equal "offtakes from", relationship_verb("offtake_with")
    assert_equal "invests in", relationship_verb(:invests_in)
    assert_equal "is a subsidiary of", relationship_verb("subsidiary_of")
    assert_equal "is the reactor developer for", facility_relationship_verb("vendor_for")
    assert_raises(KeyError) { relationship_verb("partners_with") }
  end

  test "every data type has a label" do
    assert_equal Facility.facility_types.keys.sort, FACILITY_TYPE_LABELS.keys.sort
    assert_equal Facility.statuses.keys.sort, FACILITY_STATUS_LABELS.keys.sort
    assert_equal Relationship.relationship_types.keys.sort, RELATIONSHIP_VERBS.keys.sort
    assert_equal FacilityRelationship.relationship_types.keys.sort, FACILITY_RELATIONSHIP_VERBS.keys.sort
  end

  test "every seeded role has on-screen wording" do
    roles_block = File.read(Rails.root.join("db/seeds.rb"))[/^ROLES = \[(.*?)^\]\.freeze/m, 1]
    seeded_roles = roles_block.scan(/\[ "([a-z_]+)", /).flatten

    assert_operator seeded_roles.size, :>, 10
    assert_empty seeded_roles - ROLE_LABELS.keys, "add wording for these roles to DirectoryHelper::ROLE_LABELS"
  end

  test "labels use the words in VOICE.md" do
    assert_equal "Power plant", facility_type_label("power_reactor")
    assert_equal "Reactor designer", role_label("reactor_vendor")
    assert_equal "Power buyer", role_label("data_center_offtaker")
    assert_nil facility_type_label(nil)
    assert_nil facility_status_label(nil)
  end

  test "confidence becomes bars and a word, and nothing when unknown" do
    assert_equal({ bars: 3, word: "High" }, confidence_level(1.0))
    assert_equal({ bars: 3, word: "High" }, confidence_level(0.9))
    assert_equal({ bars: 2, word: "Medium" }, confidence_level(0.8))
    assert_equal({ bars: 1, word: "Low" }, confidence_level(0.4))
    assert_nil confidence_level(nil)
  end

  test "initials take the first two words" do
    assert_equal "KP", initials("Kairos Power")
    assert_equal "XE", initials("X-energy")
    assert_equal "WE", initials("Westinghouse Electric Company")
    assert_equal "TV", initials("The Tennessee Valley Authority")
    assert_equal "O", initials("Oklo")
  end

  test "place joins what is known and is nil when nothing is" do
    assert_equal "Alameda, CA", place("Alameda", "CA")
    assert_equal "CA", place(nil, "CA")
    assert_nil place("", nil)
  end

  test "location: US city and state, a state alone, abroad, and nothing" do
    assert_equal "Bethesda, MD", location("Bethesda", "MD")
    assert_equal "Bethesda, MD", location("Bethesda", "Maryland"), "a full state name is abbreviated"
    assert_equal "Georgia", location(nil, "GA"), "a state alone is written in full"
    assert_equal "Georgia", location("", "Georgia")
    assert_equal "Courbevoie, France", location("Courbevoie", nil, country: "FR")
    assert_equal "London, United Kingdom", location("London", "England", country: "GB"), "no state abroad"
    assert_equal "France", location(nil, nil, country: "FR")
    assert_equal "Alameda", location("Alameda", nil), "a city with no state shows as it is"
    assert_nil location(nil, nil)
    assert_nil location("", "")
  end

  test "public URLs" do
    assert_equal "/companies", directory_url_for
    assert_equal "/companies?category=fuel&q=haleu", directory_url_for(category: Category.find("fuel"), q: "haleu")
    assert_equal "/companies/terrapower", company_url_for(organizations(:terrapower))
    assert_equal "/plants/vogtle", plant_url_for(facilities(:vogtle))
  end

  test "dates" do
    assert_equal "2024-10-14", data_date(Date.new(2024, 10, 14))
    assert_equal "October 2024", prose_month(Date.new(2024, 10, 14))
    assert_nil data_date(nil)
  end

  # #200: company website links carry a referral UTM so companies can see
  # the visit in their own analytics; source citations don't.
  test "with_referral_utm appends utm_source and utm_medium to a plain company URL" do
    url = with_referral_utm("https://terrapower.com")
    uri = URI.parse(url)
    params = URI.decode_www_form(uri.query).to_h
    assert_equal "nuclear-directory", params["utm_source"]
    assert_equal "referral", params["utm_medium"]
    assert_nil params["utm_campaign"]
    assert_equal "terrapower.com", uri.host, "scheme and host are unchanged"
  end

  test "with_referral_utm sets utm_campaign when given" do
    params = URI.decode_www_form(URI.parse(with_referral_utm("https://kairospower.com", campaign: "company-page")).query).to_h
    assert_equal "company-page", params["utm_campaign"]
  end

  test "with_referral_utm keeps an existing query string and doesn't clobber utm params the URL already carries" do
    url = with_referral_utm("https://example.com/path?ref=abc&utm_source=theirs", campaign: "company-page")
    params = URI.decode_www_form(URI.parse(url).query)
    assert_equal "abc", params.assoc("ref").last
    assert_equal "theirs", params.assoc("utm_source").last, "its own UTM wins"
    assert_equal "referral", params.assoc("utm_medium").last, "the ones it doesn't carry are still added"
    assert_equal "company-page", params.assoc("utm_campaign").last
    assert_equal 1, params.count { |k, _| k == "utm_source" }, "no duplicate utm_source"
  end

  test "with_referral_utm keeps the existing query byte for byte, including non-UTF-8 values" do
    url = with_referral_utm("https://example.com/?utm_source=caf%E9&q=a%20b", campaign: "company-page")

    assert url.start_with?("https://example.com/?utm_source=caf%E9&q=a%20b&")
    assert_includes url, "utm_medium=referral"
    assert_includes url, "utm_campaign=company-page"
  end

  test "with_referral_utm sees percent-encoded UTM names as the ones the URL already carries" do
    url = with_referral_utm("https://example.com/?utm%5Fsource=theirs", campaign: "company-page")

    assert url.start_with?("https://example.com/?utm%5Fsource=theirs&")
    assert_not_includes url, "utm_source=nuclear-directory"
    assert_includes url, "utm_medium=referral"
  end

  test "with_referral_utm leaves non-http URLs and blanks alone (safety: no javascript: links)" do
    assert_equal "", with_referral_utm("")
    assert_nil with_referral_utm(nil)
    assert_equal "javascript:alert(1)", with_referral_utm("javascript:alert(1)")
    assert_equal "ftp://files.example.com/x", with_referral_utm("ftp://files.example.com/x")
  end
end
