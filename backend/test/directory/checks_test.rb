require "test_helper"

# Data Quality's tags (#238), one definition for the admin's Live list and
# the coming audit report.
class Directory::ChecksTest < ActiveSupport::TestCase
  VERIFIED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  def ids(key, model) = Directory::Checks.find(key).ids(model)

  def source(url, kind: "web_page", domain: URI(url).host) = Source.create!(url:, source_kind: kind, domain:)

  test "every tag has a key, a label and a group; flags are ordered by severity" do
    assert Directory::Checks.all.all? { |tag| tag.key.present? && tag.label.present? && Directory::Checks::GROUPS.key?(tag.group) }
    assert_equal %w[no-quote source-disagrees dropped-by-source stale single-source in-review low-confidence
      unquoted-docket-place unquoted-hq unquoted-legal-name], Directory::Checks.in_group("flags").map(&:key)
  end

  test "flags: a docket, place, headquarters or legal name no own quote states" do
    nrc = source("https://www.nrc.gov/q", kind: "nrc_reactor_list")
    stated = Facility.create!(name: "Stated Site", nrc_docket: "05000111", city: "Cordova", state: "IL", **VERIFIED)
    Evidence.create!(subject: stated, source: nrc, quote: "docket 05000111, Cordova, Illinois", found_by: "crawler")
    drifted = Facility.create!(name: "Drifted Site", nrc_docket: "05000222", city: "Byron", state: "IL", **VERIFIED)
    Evidence.create!(subject: drifted, source: nrc, quote: "docket 05000222", found_by: "crawler")
    bwxt = Organization.create!(name: "BWXT", legal_name: "BWX Technologies, Inc.", hq_city: "Lynchburg", hq_state: "VA", **VERIFIED)
    Evidence.create!(subject: bwxt, source: nrc, quote: "BWX Technologies, Inc., of Lynchburg, VA", found_by: "crawler")
    edited = Organization.create!(name: "Edited Co", legal_name: "Edited Holdings LLC", hq_city: "Austin", hq_state: "TX", **VERIFIED)
    Evidence.create!(subject: edited, source: nrc, quote: "Edited Co, Dallas, TX", found_by: "crawler")

    assert_equal [ drifted.id ], ids("unquoted-docket-place", Facility) & [ stated.id, drifted.id ]
    assert_equal [ edited.id ], ids("unquoted-hq", Organization) & [ bwxt.id, edited.id ]
    assert_equal [ edited.id ], ids("unquoted-legal-name", Organization) & [ bwxt.id, edited.id ]
    assert_empty ids("unquoted-hq", Facility), "each applies to its own kind of record"
  end

  test "status: live, hidden, merged" do
    live = Organization.create!(name: "Live Co", **VERIFIED)
    merged = Organization.create!(name: "Merged Co", **VERIFIED)
    Directory::FactWriter.merge_organization(from_id: merged.id, into_id: live.id, by: "human:tosin")
    site = Facility.create!(name: "Down Site", **VERIFIED)
    hidden = Facility.create!(name: "Down 1", parent: site, **VERIFIED)
    site.unpublish!(by: "human:tosin", reason: "Test")

    assert_includes ids("live", Organization), live.id
    assert_includes ids("merged", Organization), merged.id
    assert_not_includes ids("merged", Organization), live.id
    assert_includes ids("hidden", Facility), hidden.id
  end

  test "flags: no quote, one source, two or more sources" do
    a = source("https://www.nrc.gov/a", kind: "nrc_reactor_list")
    b = source("https://www.energy.gov/b")
    quoted_once = Organization.create!(name: "Once Co", **VERIFIED)
    Evidence.create!(subject: quoted_once, source: a, quote: "Once Co", found_by: "crawler")
    twice = Organization.create!(name: "Twice Co", **VERIFIED)
    Evidence.create!(subject: twice, source: a, quote: "Twice", found_by: "crawler")
    Evidence.create!(subject: twice, source: b, quote: "Twice", found_by: "human")
    unquoted = Organization.create!(name: "Bare Co", **VERIFIED)
    Evidence.create!(subject: unquoted, source: b, quote: "", found_by: "human")

    blank = Organization.create!(name: "Blank Co", **VERIFIED)
    Evidence.create!(subject: blank, source: b, quote: " \n ", found_by: "human")

    assert_equal [ unquoted.id, blank.id ].sort, (ids("no-quote", Organization) & [ quoted_once.id, twice.id, unquoted.id, blank.id ]).sort, "spaces or newlines are no quote"
    assert_includes ids("single-source", Organization), quoted_once.id
    assert_not_includes ids("single-source", Organization), twice.id
    assert_includes ids("multi-source", Organization), twice.id
    assert_includes ids("nrc", Organization), twice.id
    assert_includes ids("hand-research", Organization), twice.id
  end

  test "flags: stale after 14 days for NRC, a year for web research" do
    nrc = source("https://www.nrc.gov/list", kind: "nrc_reactor_list")
    web = source("https://www.example.com/news")
    old_nrc = Facility.create!(name: "Old NRC 1", **VERIFIED)
    old_web = Organization.create!(name: "Old Web Co", **VERIFIED)
    travel_to(20.days.ago) do
      Evidence.create!(subject: old_nrc, source: nrc, quote: "x", found_by: "crawler")
      Evidence.create!(subject: old_web, source: web, quote: "x", found_by: "human")
    end

    assert_includes ids("stale", Facility), old_nrc.id
    assert_not_includes ids("stale", Organization), old_web.id
  end

  test "flags: NRC's decommissioning list is NRC too, stale after 14 days" do
    list = source("https://www.nrc.gov/decommissioning", kind: "nrc_decommissioning")
    old_unit = Facility.create!(name: "Old Decommissioning 1", **VERIFIED)
    travel_to(20.days.ago) { Evidence.create!(subject: old_unit, source: list, quote: "x", found_by: "crawler") }

    assert_includes ids("stale", Facility), old_unit.id
    assert_includes ids("nrc", Facility), old_unit.id
  end

  test "gaps: no operator, no category, no links, no share" do
    plant = Facility.create!(name: "Lonely Plant", status: "operating", **VERIFIED)
    operated = Facility.create!(name: "Run Plant", status: "operating", **VERIFIED)
    unit = Facility.create!(name: "Run 1", parent: operated, status: "operating", **VERIFIED)
    company = Organization.create!(name: "Operator Co", **VERIFIED)
    FacilityRelationship.create!(organization: company, facility: unit, relationship_type: "operates", **VERIFIED)
    alone = Organization.create!(name: "Alone Co", **VERIFIED)
    a, b = Organization.create!(name: "Owner A", **VERIFIED), Organization.create!(name: "Owner B", **VERIFIED)
    shareless = FacilityRelationship.create!(organization: a, facility: plant, relationship_type: "owns", **VERIFIED)
    FacilityRelationship.create!(organization: b, facility: plant, relationship_type: "owns", ownership_pct: 50, **VERIFIED)

    assert_includes ids("no-operator", Facility), plant.id
    assert_not_includes ids("no-operator", Facility), operated.id, "its unit's operator counts for the site"
    assert_includes ids("no-category", Organization), alone.id
    assert_includes ids("no-links", Organization), alone.id
    assert_not_includes ids("no-links", Organization), company.id
    assert_equal [ shareless.id ], ids("no-share", FacilityRelationship) & [ shareless.id ]
    assert_not Directory::Checks.find("no-operator").applies_to?(Organization)
  end

  test "gaps count only links in effect today: an ended operator leaves the gap, successive owners aren't co-owners" do
    plant = Facility.create!(name: "Handed Over Plant", status: "operating", **VERIFIED)
    old, new = Organization.create!(name: "Old Op", **VERIFIED), Organization.create!(name: "New Owner", **VERIFIED)
    FacilityRelationship.create!(organization: old, facility: plant, relationship_type: "operates", ended_on: 1.year.ago, **VERIFIED)
    FacilityRelationship.create!(organization: old, facility: plant, relationship_type: "owns", ended_on: 1.year.ago, **VERIFIED)
    current = FacilityRelationship.create!(organization: new, facility: plant, relationship_type: "owns", **VERIFIED)

    assert_includes ids("no-operator", Facility), plant.id
    assert_not_includes ids("no-share", FacilityRelationship), current.id
  end

  test "No share works out today's co-owners when it's asked, not when the tags were built" do
    plant = Facility.create!(name: "Ending Share Plant", status: "operating", **VERIFIED)
    a, b = Organization.create!(name: "Staying Owner", **VERIFIED), Organization.create!(name: "Leaving Owner", **VERIFIED)
    staying = FacilityRelationship.create!(organization: a, facility: plant, relationship_type: "owns", **VERIFIED)
    FacilityRelationship.create!(organization: b, facility: plant, relationship_type: "owns", ended_on: 1.day.from_now, ownership_pct: 50, **VERIFIED)

    assert_includes ids("no-share", FacilityRelationship), staying.id
    travel_to(2.days.from_now) { assert_not_includes ids("no-share", FacilityRelationship), staying.id, "the other owner has left" }
  end

  test "source disagrees: an open disagreement, or a source's latest reading that a person's decision overrules" do
    source = Source.create!(url: "https://www.nrc.gov/disagree", source_kind: "nrc_reactor_list", domain: "nrc.gov")
    overruled = Facility.create!(name: "Overruled 1", **VERIFIED)
    settled = Facility.create!(name: "Settled 1", **VERIFIED)
    claim = ->(subject, notes, status = "confirmed") { Candidate.create!(source:, kind: "facility", payload: {}, quote: "q", status:, notes:, subject_type: "Facility", subject_id: subject.id) }
    claim.(overruled, "Confirmed by human:tosin: identical, except where a person's decision stands: status shut_down (it says operating)")
    claim.(settled, "Confirmed: except where a person's decision stands: status shut_down (it says operating)")
    claim.(settled, "Confirmed by human:tosin: identical to Settled 1 as decided") # the source now agrees

    ids = ids("source-disagrees", Facility)

    assert_includes ids, overruled.id
    assert_not_includes ids, settled.id, "only each source's latest reading counts"
  end

  test "low confidence is the fact's own confidence, not one source's" do
    low = Organization.create!(name: "Unsure Co", verification_status: "pending", confidence: 0.6)
    combined = Organization.create!(name: "Two Sources Co", verification_status: "pending", confidence: 0.7)

    assert_includes ids("low-confidence", Organization), low.id
    assert_not_includes ids("low-confidence", Organization), combined.id
  end

  test "decided by: a person, and edited by a person" do
    org = Organization.create!(name: "Edited Co", **VERIFIED)
    VerificationEvent.create!(subject: org, from_status: "verified", to_status: "verified", by: "human:tosin", changed_values: { "hq_state" => [ "DE", "WA" ] })

    assert_includes ids("human-verified", Organization), org.id
    assert_includes ids("human-edited", Organization), org.id
  end
end
