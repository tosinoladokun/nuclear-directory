require "test_helper"

# PM, 3 Nov: a company or plant page is cached under its own stamp
# (PageStamps). This fails if the page reads any record whose change wouldn't
# move that stamp, so a new section (Similar companies, Latest, …) can't go
# stale. If it fails: add what the section reads to PageStamps, or keep the
# section out of page_cache.
class PageStampsCoverageTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze

  # Every record instantiated while a page renders.
  module Recorder
    mattr_accessor :seen
    def init_with_attributes(...)
      super.tap { Recorder.seen&.add([ self.class.base_class, id ]) }
    end
  end
  ActiveRecord::Base.prepend(Recorder)

  def verified(model, **attributes) = model.create!(verification_status: "verified", verified_by: BY, **attributes)

  def cite(record, quote = "t")
    Evidence.create!(subject: record, source: @source, quote:, found_by: "human")
    record
  end

  setup do
    @source = Source.create!(url: "https://example.com/stamps", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t", title: "A page")
    @company = cite(verified(Organization, name: "Stamp Co", slug: "stamp-co", description: "Builds reactors.", hq_city: "Austin", hq_state: "TX"))
    @company.aliases.create!(alias: "Stamp Company Inc")
    partner = cite(verified(Organization, name: "Stamp Buyer", slug: "stamp-buyer"))
    role = Role.find_or_create_by!(key: "reactor_vendor") { |r| r.name = "Reactor vendor" }
    cite(verified(OrganizationRole, organization: @company, role:))
    cite(verified(OrganizationRole, organization: partner, role: Role.find_or_create_by!(key: "utility") { |r| r.name = "Utility" }))
    cite(verified(OrganizationTechnology, organization: @company, technology: Technology.find_or_create_by!(key: "smr") { |t| t.name = "Small modular reactor" }))
    link = cite(verified(Relationship, from_organization: partner, to_organization: @company, relationship_type: "offtake_with"))
    cite(verified(DealTerm, link:, term_type: "offtake", agreement: "ppa", status: "signed", capacity_mw: 50, signed_on: Date.new(2026, 1, 5)))
    @site = cite(verified(Facility, name: "Stamp Station", slug: "stamp-station", facility_type: "power_reactor", city: "Glen Rose", state: "TX"))
    unit = cite(verified(Facility, name: "Stamp Station 1", slug: "stamp-station-1", parent: @site, nrc_docket: "05000990", facility_type: "power_reactor", status: "operating"))
    unit.aliases.create!(alias: "SS-1")
    cite(verified(FacilityRelationship, organization: @company, facility: unit, relationship_type: "vendor_for"))
    cite(verified(FacilityRelationship, organization: partner, facility: @site, relationship_type: "owns"))
    cite(verified(LicensingStage, facility: unit, stage: "operating_licence", nrc_docket: "05000990", effective_on: Date.new(2020, 1, 1)),
      "NRC operating licence 05000990")
    # Similar companies (#678): a company sharing a role and a technology.
    peer = cite(verified(Organization, name: "Stamp Peer", slug: "stamp-peer", description: "Also builds reactors."))
    cite(verified(OrganizationRole, organization: peer, role:))
    cite(verified(OrganizationTechnology, organization: peer, technology: Technology.find_by!(key: "smr")))
    news = verified(NewsItem, url: "https://www.federalregister.gov/d/stamps", title: "Stamp Co news", published_on: Date.current, summary: "s")
    news.news_mentions.create!(subject: @company)
    news.news_mentions.create!(subject: @site)
  end

  def records_read(path)
    Recorder.seen = Set.new
    get path
    assert_response :success
    Recorder.seen
  ensure
    seen = Recorder.seen
    Recorder.seen = nil
    seen
  end

  # Changes a record the way a write would: a later updated_at, or for
  # evidence (no updated_at) its quote.
  def touch(model, id)
    if model == Evidence then Evidence.where(id:).update_all("quote = quote || ' changed'")
    elsif model.column_names.include?("updated_at") then model.where(id:).update_all(updated_at: 1.hour.from_now)
    end
  end

  def assert_covered(path, &stamp)
    read = records_read(path).reject { |model, _| [ VerificationEvent ].include?(model) }
    assert_operator read.size, :>, 10, "the page read its facts"
    stale = read.select do |model, id|
      before = stamp.call
      changed = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        touch(model, id)
        changed = stamp.call != before
        raise ActiveRecord::Rollback
      end
      !changed
    end
    assert_empty stale.map { |model, id| "#{model.name} ##{id}" },
      "#{path} reads these, but changing them doesn't change its stamp: add them to PageStamps or keep that section out of page_cache"
  end

  test "everything a company page reads is in its stamp" do
    assert_covered("/companies/stamp-co") { PageStamps.company(@company.id) }
  end

  test "everything a plant page reads is in its stamp" do
    assert_covered("/plants/stamp-station") { PageStamps.plant(@site.id) }
  end

  # Each kind of change that should rebuild the pages showing it (Infra).
  def assert_moves(stamp, why)
    before = stamp.call
    yield
    assert_not_equal before, stamp.call, why
  end

  test "each kind of dependency moves the stamps of the pages that show it" do
    company = -> { PageStamps.company(@company.id) }
    plant = -> { PageStamps.plant(@site.id) }
    partner = Organization.find_by!(slug: "stamp-buyer")
    assert_moves(company, "a partner's first source") { cite(partner, "another quote") }
    assert_moves(plant, "a listed company's new source") { cite(partner, "a third quote") }
    assert_moves(company, "a partner's role") { OrganizationRole.where(organization: partner).update_all(updated_at: 1.hour.from_now) }
    peer = Organization.find_by!(slug: "stamp-peer")
    assert_moves(company, "a similar company renamed") { peer.update!(name: "Stamp Peer Renamed") }
    assert_moves(company, "a similar company's role") { OrganizationRole.where(organization: peer).update_all(updated_at: 5.hours.from_now) }
    assert_moves(company, "a similar company's technology") { OrganizationTechnology.where(organization: peer).update_all(updated_at: 6.hours.from_now) }
    assert_moves(company, "a news item edited") { NewsItem.update_all(updated_at: 2.hours.from_now) }
    assert_moves(plant, "a news item edited") { NewsItem.update_all(updated_at: 3.hours.from_now) }
    assert_moves(company, "a deal term edited") { DealTerm.update_all(updated_at: 4.hours.from_now) }
    assert_moves(plant, "a unit renamed") { Facility.find_by!(slug: "stamp-station-1").update!(name: "Stamp Station Unit 1") }
    assert_moves(company, "a plant it links to renamed") { Facility.find_by!(slug: "stamp-station-1").update!(name: "Stamp Station One") }
  end
end
