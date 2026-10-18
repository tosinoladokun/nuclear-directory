require "test_helper"

# Lets a test run something just before the backfill writes a deal term (a
# merge landing in between). Inert unless a test sets the thread's hook.
module BeforeDealTermWrite
  def write(kind, attributes, **options)
    hook = Thread.current[:before_deal_term_write]
    hook.call(attributes.to_h.symbolize_keys) if hook && kind.to_s == "deal_term"
    super
  end
end
Directory::FactWriter.singleton_class.prepend(BeforeDealTermWrite) unless Directory::FactWriter.singleton_class.include?(BeforeDealTermWrite)
require "rake"

class DirectoryRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("directory:backfill_former_slugs")
  end

  def backfill = Rake::Task["directory:backfill_former_slugs"].execute

  def backfill_merged_into(**env)
    env.each { |key, value| ENV[key.to_s] = value }
    Rake::Task["directory:backfill_merged_into"].execute
  ensure
    env.each_key { |key| ENV.delete(key.to_s) }
  end

  # An event as merges wrote it before #166: the target only in the reason.
  def old_event(subject, to_status, reason)
    VerificationEvent.create!(subject:, from_status: "verified", to_status:, by: "human:tosin", reason:)
  end

  test "backfill_merged_into records past merges' targets from their reasons, and only merges (#166)" do
    urenco = Organization.create!(name: "Urenco")
    usa = Organization.create!(name: "Urenco USA")
    plant = Facility.create!(name: "Plant Vogtle")
    vogtle = Facility.create!(name: "Vogtle")
    merged = old_event(usa, "unpublished", "One company per brand (decision #23): Urenco USA is part of Urenco. Merged into Urenco (##{urenco.id}). Moved: 3 aliases")
    site = old_event(vogtle, "unpublished", "Merged into Plant Vogtle (##{plant.id}). Moved: 1 alias")
    # Not merges into anything: a fact a merge retired, and the kept record's own event.
    retired = old_event(OrganizationRole.create!(organization: usa, role: Role.create!(key: "enrichment_test", name: "Enrichment")), "rejected", "Merged into Urenco (##{urenco.id}); Urenco already has this")
    winner = old_event(plant, "verified", "Vogtle (##{vogtle.id}) merged in: its eia_plant_id")

    assert_output(/event #{merged.id}: Organization #{usa.id} -> Urenco \(##{urenco.id}\)\nevent #{site.id}: .*\n2 would be recorded\.\nDry run/) do
      backfill_merged_into(BY: "human:tosin")
    end
    assert_nil merged.reload.context["merged_into"], "a dry run changes nothing"

    assert_output(/2 recorded/) { backfill_merged_into(BY: "human:tosin", APPLY: "1") }
    assert_equal({ "type" => "Organization", "id" => urenco.id }, merged.reload.context["merged_into"])
    assert_equal({ "type" => "Facility", "id" => plant.id }, site.reload.context["merged_into"])
    assert_equal "human:tosin", merged.context["merged_into_backfilled_by"]
    assert_equal [ {}, {} ], [ retired.reload.context, winner.reload.context ]
    assert_equal merged.reason, VerificationEvent.find(merged.id).reason, "nothing else changes"

    assert_output("No merge events without merged_into.\n") { backfill_merged_into(BY: "human:tosin", APPLY: "1") }
    assert_raises(SystemExit) { capture_io { backfill_merged_into(BY: "human:") } }
  end

  test "backfill_merged_into counts a merge whose target is gone as skipped, not recorded" do
    urenco = Organization.create!(name: "Urenco")
    gone = old_event(Organization.create!(name: "Old Co"), "unpublished", "Merged into Nobody (#999999). Moved: 1 alias")
    kept = old_event(Organization.create!(name: "Urenco USA"), "unpublished", "Merged into Urenco (##{urenco.id}). Moved: 1 alias")

    assert_output(/skipped, no Organization #999999\n.*\n1 would be recorded, 1 skipped\./m) { backfill_merged_into(BY: "human:tosin") }
    assert_output(/1 recorded, 1 skipped\./) { backfill_merged_into(BY: "human:tosin", APPLY: "1") }
    assert_equal [ {}, urenco.id ], [ gone.reload.context, kept.reload.context.dig("merged_into", "id") ]
  end

  test "the backfill keeps slugs renamed or merged before #143, and is safe to rerun" do
    atr = Facility.create!(name: "Advanced Test Reactor", slug: "advanced-test-reactor")
    VerificationEvent.create!(subject: atr, from_status: "verified", to_status: "verified", by: "human:tosin",
      changed_values: { "slug" => [ "advanced-test-reactor-atr", "advanced-test-reactor" ] })
    urenco = Organization.create!(name: "Urenco")
    usa = Organization.create!(name: "Urenco USA")
    usa.unpublish!(by: "human:tosin", reason: "One company per brand. Merged into Urenco (##{urenco.id}). Moved: 3 aliases")
    FormerSlug.delete_all

    assert_output(/Facility advanced-test-reactor-atr -> advanced-test-reactor\nOrganization urenco-usa -> urenco/) { backfill }
    assert_equal atr, Facility.find_by_former_slug("advanced-test-reactor-atr")
    assert_equal urenco, Organization.find_by_former_slug("urenco-usa")

    assert_output("Nothing to backfill.\n") { backfill }
  end

  def merge(task, from, into, **env)
    env.each { |key, value| ENV[key.to_s] = value }
    Rake::Task["directory:#{task}"].execute(Rake::TaskArguments.new(%i[from into], [ from.to_s, into.to_s ]))
  ensure
    env.each_key { |key| ENV.delete(key.to_s) }
  end

  def retire_eia_operators(**env)
    env.each { |key, value| ENV[key.to_s] = value }
    Rake::Task["directory:retire_eia_operators"].execute
  ensure
    env.each_key { |key| ENV.delete(key.to_s) }
  end

  test "merging a duplicate site is a dry run until APPLY=1, then audited as the named person (#229)" do
    vogtle = Facility.create!(name: "Plant Vogtle", verification_status: "verified", verified_by: "human:tosin")
    eia = Facility.create!(name: "Vogtle", eia_plant_id: "649", verification_status: "verified", verified_by: "human:tosin")

    assert_output(/Would merge Vogtle \(##{eia.id}\) into Plant Vogtle \(##{vogtle.id}\): .*Moved: 1 alias, eia_plant_id\nDry run/) do
      merge(:merge_facility, eia.id, vogtle.id, BY: "human:tosin")
    end
    assert_equal [ "verified", nil ], [ eia.reload.verification_status, vogtle.reload.eia_plant_id ]

    assert_output(/\AMerged Vogtle/) { merge(:merge_facility, eia.id, vogtle.id, BY: "human:tosin", APPLY: "1") }
    assert eia.reload.unpublished?
    assert_equal [ "649", "human:tosin" ], [ vogtle.reload.eia_plant_id, eia.verified_by ]

    assert_raises(SystemExit) { capture_io { merge(:merge_facility, eia.id, vogtle.id, BY: "human:tosin", APPLY: "1") } }
    assert_raises(SystemExit) { capture_io { merge(:merge_facility, eia.id, vogtle.id, BY: "human:") } }
  end

  test "merging a duplicate company works the same way" do
    talen = Organization.create!(name: "Talen Energy", verification_status: "verified", verified_by: "human:tosin")
    eia = Organization.create!(name: "TalenEnergy", verification_status: "verified", verified_by: "human:tosin")

    assert_output(/Would merge TalenEnergy/) { merge(:merge_organization, eia.id, talen.id, BY: "human:tosin") }
    assert eia.reload.verified?
    assert_output(/\AMerged TalenEnergy/) { merge(:merge_organization, eia.id, talen.id, BY: "human:tosin", APPLY: "1") }
    assert eia.reload.unpublished?
    assert_raises(SystemExit) { capture_io { merge(:merge_organization, eia.id, talen.id, BY: "human:tosin", APPLY: "1") } }
  end

  def operates(company, plant, *sources)
    FacilityRelationship.create!(organization: company, facility: plant, relationship_type: "operates").tap do |link|
      sources.each { |source| link.evidence.create!(source:, found_by: "crawler", quote: "row") }
      link.verify!(by: "human:tosin")
    end
  end

  PUBLISHED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  def company(name) = Organization.create!(name:, **PUBLISHED)
  def plant(name, **attributes) = Facility.create!(name:, **PUBLISHED, **attributes)

  test "published operates links only EIA backs are listed, and unpublished on APPLY where NRC names another operator (#227)" do
    eia = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx", source_kind: "eia_generators")
    nrc = Source.create!(url: "https://www.nrc.gov/test/operators", source_kind: "nrc_reactor_list")
    hatch = plant("Edwin I Hatch", eia_plant_id: "6051")
    wrong = operates(company("Georgia Power"), hatch, eia)
    operates(company("Southern Nuclear"), plant("Hatch 1", parent: hatch, nrc_docket: "05000321"), nrc)
    columbia = plant("Columbia", eia_plant_id: "371")
    alone = operates(company("Energy Northwest"), columbia, eia)
    operates(company("Bonneville Power"), columbia, eia) # another EIA-only operator isn't NRC's word
    both = operates(company("Entergy"), plant("Arkansas Nuclear One", eia_plant_id: "8055"), eia, nrc)
    salem = plant("Salem", eia_plant_id: "2410")
    current = operates(company("PSEG Nuclear"), salem, eia)
    operates(company("Public Service Electric & Gas"), salem, nrc).update_columns(ended_on: Date.new(2000, 1, 1))
    # Hidden: its company was taken down, so the task leaves it be.
    hidden = operates(gone = company("Gone Co"), hatch, eia)
    gone.unpublish!(by: "human:tosin", reason: "Not a real company")

    assert_output(/Georgia Power operates Edwin I Hatch -> would unpublish \(Southern Nuclear\)\n/) { retire_eia_operators }
    assert_output(/Energy Northwest operates Columbia \(no published NRC operator; check by hand\)/) { retire_eia_operators(APPLY: "0") }
    assert wrong.reload.verified?, "a dry run, and APPLY=0, change nothing"
    assert_raises(SystemExit) { capture_io { retire_eia_operators(APPLY: "1") } }
    assert_raises(SystemExit) { capture_io { retire_eia_operators(APPLY: "1", BY: "human:") } }

    assert_output(/Georgia Power operates Edwin I Hatch -> unpublished/) { retire_eia_operators(APPLY: "1", BY: "human:tosin") }
    assert wrong.reload.unpublished?
    assert_equal "human:tosin", wrong.verified_by
    assert alone.reload.verified?, "no NRC operator to go by"
    assert both.reload.verified?, "NRC backs it too"
    assert hidden.reload.verified?, "not published, so not this task's"
    assert current.reload.verified?, "NRC's only operator there ended in 2000"
  end

  test "a link named in SKIP is listed but kept, even with APPLY (Perry, #237)" do
    eia = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx", source_kind: "eia_generators")
    nrc = Source.create!(url: "https://www.nrc.gov/test/operators", source_kind: "nrc_reactor_list")
    perry = plant("Perry", eia_plant_id: "6020")
    kept = operates(company("Energy Harbor Nuclear Corp."), perry, eia)
    operates(company("FirstEnergy Nuclear Operating Co."), plant("Perry 1", parent: perry, nrc_docket: "05000440"), nrc)

    assert_output(/Energy Harbor Nuclear Corp. operates Perry -> kept \(SKIP; FirstEnergy Nuclear Operating Co.\)/) do
      retire_eia_operators(APPLY: "1", BY: "human:tosin", SKIP: " #{kept.id} ")
    end
    assert kept.reload.verified?
    assert_raises(SystemExit) { capture_io { retire_eia_operators(SKIP: "Perry") } }
  end

  def backfill_award_terms(**env)
    env.each { |key, value| ENV[key.to_s] = value }
    Rake::Task["directory:backfill_award_terms"].execute
  ensure
    env.each_key { |key| ENV.delete(key.to_s) }
  end

  def set_status(status, ids, **env)
    env.each { |key, value| ENV[key.to_s] = value }
    Rake::Task["directory:set_status"].execute(Rake::TaskArguments.new(%i[status ids], [ status, ids ]))
  ensure
    env.each_key { |key| ENV.delete(key.to_s) }
  end

  test "award terms are written from a funds link's own USAspending rows, verified only with a verified link (#256)" do
    by = "human:tosin"
    doe = Organization.create!(name: "U.S. Department of Energy", verification_status: "verified", verified_by: by)
    xenergy = Organization.create!(name: "X-energy", verification_status: "verified", verified_by: by)
    other = Organization.create!(name: "Kairos Power")
    verified = Relationship.create!(from_organization: doe, to_organization: xenergy, relationship_type: "funds",
      verification_status: "verified", verified_by: by)
    pending = Relationship.create!(from_organization: doe, to_organization: other, relationship_type: "funds")
    columns = %w[award_id recipient_name amount_usd start_date end_date award_type assistance_listing search award_url
      generated_award_id recipient_id description]
    page = ->(url, rows) do
      Source.create!(url:, source_kind: "usaspending_doe_awards", crawl_status: "ok",
        content_text: CSV.generate { |csv| csv << columns; rows.each { |row| csv << row } })
    end
    xenergy_page = page.("https://www.usaspending.gov/recipient/x-energy/latest", [
      [ "DE-NE0009040", "X ENERGY, LLC", "80000000.00", "2020-10-13", "2027-09-30", "assistance", "81.121", "nuclear",
        "https://www.usaspending.gov/award/ASST_A", "ASST_A", "x-C", "ARDP" ],
      [ "89243223CNE000030", "X ENERGY, LLC", "1200000.00", "2023-01-05", "", "contract", "", "fuel",
        "https://www.usaspending.gov/award/CONT_B", "CONT_B", "x-C", "HALEU" ]
    ])
    kairos_page = page.("https://www.usaspending.gov/recipient/kairos/latest", [
      [ "DE-NE0009300", "KAIROS POWER LLC", "303000000.00", "2020-12-16", "", "assistance", "81.121", "nuclear",
        "https://www.usaspending.gov/award/ASST_C", "ASST_C", "k-C", "Hermes" ]
    ])
    verified.evidence.create!(source: xenergy_page, quote: "row", found_by: "crawler", confidence: 1)
    pending.evidence.create!(source: kairos_page, quote: "row", found_by: "crawler", confidence: 1)

    assert_output(/3 award terms would be written, 0 already there.\nDry run/) { backfill_award_terms(BY: by) }
    assert_equal 0, DealTerm.count

    assert_output(/3 award terms written, 0 already there/) { backfill_award_terms(BY: by, APPLY: "1") }
    assert_equal %w[ASST_A CONT_B], DealTerm.where(link: verified).order(:external_id).pluck(:external_id)
    assert DealTerm.where(link: verified).all?(&:verified?), "a verified link's terms are verified"
    assert DealTerm.find_by!(external_id: "ASST_C").pending?, "a pending link's terms wait with it"
    assert_equal "contract", DealTerm.find_by!(external_id: "CONT_B").program
    assert_equal [ xenergy_page.id ], DealTerm.find_by!(external_id: "ASST_A").evidence.pluck(:source_id)

    assert_output(/0 award terms written, 3 already there/) { backfill_award_terms(BY: by, APPLY: "1") }

    # One link backed by two recipient pages (BWXT has two USAspending recipients).
    second_page = page.("https://www.usaspending.gov/recipient/x-energy-2/latest", [
      [ "DE-NE0009999", "X-ENERGY LLC", "5000000.00", "2025-02-01", "", "assistance", "81.121", "nuclear",
        "https://www.usaspending.gov/award/ASST_D", "ASST_D", "x2-C", "Fuel" ]
    ])
    verified.evidence.create!(source: second_page, quote: "row", found_by: "crawler")
    assert_output(/1 award terms written, 3 already there/) { backfill_award_terms(BY: by, APPLY: "1") }
    assert_equal second_page.id, DealTerm.find_by!(external_id: "ASST_D").evidence.sole.source_id

    # A company merged into X-energy before the backfill: its DOE link was retired, and its awards land on X-energy's.
    duplicate = Organization.create!(name: "X-energy Duplicate", verification_status: "verified", verified_by: by)
    retired = Relationship.create!(from_organization: doe, to_organization: duplicate, relationship_type: "funds",
      verification_status: "verified", verified_by: by)
    retired.evidence.create!(source: page.("https://www.usaspending.gov/recipient/x-energy-dup/latest", [
      [ "DE-NE0008888", "X ENERGY DUP", "7000000.00", "2024-03-01", "", "assistance", "81.121", "nuclear",
        "https://www.usaspending.gov/award/ASST_E", "ASST_E", "xd-C", "Dup" ]
    ]), quote: "row", found_by: "crawler")
    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: xenergy.id, by:).ok?
    assert retired.reload.rejected?
    assert_output(/1 award terms written, 4 already there/) { backfill_award_terms(BY: by, APPLY: "1") }
    assert_equal verified, DealTerm.find_by!(external_id: "ASST_E").link

    # A chain (A into B, B into X-energy), a link a person closed before its merge, and a rejected term.
    a = Organization.create!(name: "Chain A", verification_status: "verified", verified_by: by)
    b = Organization.create!(name: "Chain B", verification_status: "verified", verified_by: by)
    award_row = ->(id, recipient) do
      [ id, recipient, "1000000.00", "2024-05-01", "", "assistance", "81.121", "nuclear", "https://www.usaspending.gov/award/#{id}", id, "c-C", "Chain" ]
    end
    link_a = Relationship.create!(from_organization: doe, to_organization: a, relationship_type: "funds", verification_status: "verified", verified_by: by)
    link_b = Relationship.create!(from_organization: doe, to_organization: b, relationship_type: "funds", verification_status: "verified", verified_by: by)
    link_a.evidence.create!(source: page.("https://www.usaspending.gov/recipient/a/latest", [ award_row.("ASST_A1", "A") ]), quote: "row", found_by: "crawler")
    link_b.evidence.create!(source: page.("https://www.usaspending.gov/recipient/b/latest", [ award_row.("ASST_B1", "B") ]), quote: "row", found_by: "crawler")
    closed_co = Organization.create!(name: "Closed Co", verification_status: "verified", verified_by: by)
    closed = Relationship.create!(from_organization: doe, to_organization: closed_co, relationship_type: "funds",
      verification_status: "verified", verified_by: by)
    closed.evidence.create!(source: page.("https://www.usaspending.gov/recipient/closed/latest", [ award_row.("ASST_CLOSED", "C") ]),
      quote: "row", found_by: "crawler")
    closed.reject!(by:, reason: "Not a DOE award to this company")
    DealTerm.find_by!(external_id: "ASST_E").reject!(by:, reason: "Wrong award")

    assert Directory::FactWriter.merge_organization(from_id: a.id, into_id: b.id, by:).ok?
    assert Directory::FactWriter.merge_organization(from_id: b.id, into_id: xenergy.id, by:).ok?
    assert Directory::FactWriter.merge_organization(from_id: closed_co.id, into_id: xenergy.id, by:).ok?

    capture_io { backfill_award_terms(BY: by, APPLY: "1") }
    assert_equal verified, DealTerm.find_by!(external_id: "ASST_A1").link, "A's award, two merges away"
    assert_equal verified, DealTerm.find_by!(external_id: "ASST_B1").link
    assert_nil DealTerm.find_by(external_id: "ASST_CLOSED"), "a link a person closed before the merge stays closed"
    assert_equal 1, DealTerm.where(external_id: "ASST_E").count, "a rejected term isn't written again"
    assert DealTerm.find_by!(external_id: "ASST_E").rejected?

    # A duplicate DOE record merged into DOE: its link to X-energy was retired, and its award lands on DOE's.
    doe_dup = Organization.create!(name: "DOE Duplicate", verification_status: "verified", verified_by: by)
    dup_link = Relationship.create!(from_organization: doe_dup, to_organization: xenergy, relationship_type: "funds",
      verification_status: "verified", verified_by: by)
    dup_link.evidence.create!(source: page.("https://www.usaspending.gov/recipient/x-energy-doe-dup/latest", [ award_row.("ASST_F", "X") ]),
      quote: "row", found_by: "crawler")
    assert Directory::FactWriter.merge_organization(from_id: doe_dup.id, into_id: doe.id, by:).ok?
    assert dup_link.reload.rejected?
    capture_io { backfill_award_terms(BY: by, APPLY: "1") }
    assert_equal verified, DealTerm.find_by!(external_id: "ASST_F").link, "a funder-side merge"

    # A merge retires a link between the backfill reading it and writing its award: the write is refused, and a rerun puts it on the kept link.
    late = Organization.create!(name: "X-energy Late", verification_status: "verified", verified_by: by)
    late_link = Relationship.create!(from_organization: doe, to_organization: late, relationship_type: "funds", verification_status: "verified", verified_by: by)
    late_link.evidence.create!(source: page.("https://www.usaspending.gov/recipient/x-energy-late/latest", [ award_row.("ASST_G", "X") ]),
      quote: "row", found_by: "crawler")
    Thread.current[:before_deal_term_write] = lambda do |attributes|
      next unless attributes[:external_id] == "ASST_G" && !late.reload.unpublished?

      Directory::FactWriter.merge_organization(from_id: late.id, into_id: xenergy.id, by:)
    end
    begin
      assert_output(/1 failed/) { backfill_award_terms(BY: by, APPLY: "1") }
    ensure
      Thread.current[:before_deal_term_write] = nil
    end
    assert_not DealTerm.exists?(link: late_link), "nothing hidden on the retired link"
    capture_io { backfill_award_terms(BY: by, APPLY: "1") }
    assert_equal verified, DealTerm.find_by!(external_id: "ASST_G").link, "the rerun writes onto the kept link"
    assert_raises(SystemExit) { capture_io { backfill_award_terms(BY: "agent:x") } }
  end

  test "set_status: Palisades not operating, quoting NRC's status file; a dry run first, then human-verified for good" do
    status_file = Source.create!(url: "https://www.nrc.gov/status-#{SecureRandom.hex(3)}.txt", source_kind: "nrc_power_status", fetched_at: Time.current,
      content_text: "ReportDt|Unit|Power\n10/13/2026 12:00:00 AM|Palisades|0\n10/14/2026 12:00:00 AM|Palisades|0\n")
    site = Facility.create!(name: "Palisades", status: "operating", verification_status: "verified", verified_by: "human:tosin")
    unit = Facility.create!(name: "Palisades", parent: site, nrc_docket: "05000255", status: "operating", verification_status: "verified", verified_by: "agent:verify")
    ids = "#{unit.id} #{site.id}"

    assert_output(/Would set Palisades \(##{unit.id}\): operating -> not_operating, quoting "10\/14\/2026 12:00:00 AM\|Palisades\|0".*Dry run/m) do
      set_status("not_operating", ids, BY: "human:tosin")
    end
    assert unit.reload.operating?, "a dry run changes nothing"

    assert_output(/Set Palisades \(##{site.id}\): operating -> not_operating/) { set_status("not_operating", ids, BY: "human:tosin", APPLY: "1") }
    [ unit, site ].each do |facility|
      facility.reload
      assert facility.not_operating?
      assert facility.human_verified?
      assert_equal [ "10/14/2026 12:00:00 AM|Palisades|0" ], facility.evidence.where(source: status_file).pluck(:quote)
    end
    assert_output(/Palisades \(##{unit.id}\) is already not_operating; nothing to change/) do
      assert_no_difference(-> { VerificationEvent.count }) { set_status("not_operating", ids, BY: "human:tosin", APPLY: "1") }
    end
    assert_not_includes Facility.operating.ids, unit.id, "operating counts leave it out"
    assert_equal "Not operating", ApplicationController.helpers.facility_status_label(unit.status)

    # The crawler's "operating" doesn't flip a person's decision back.
    result = Directory::FactWriter.write(:facility, { id: unit.id, status: "operating" }, protect_human_verified: true)
    assert result.conflicts.present?
    assert unit.reload.not_operating?
  end

  test "set_status needs a person, a known status and a quote that's in the file" do
    assert_raises(SystemExit) { capture_io { set_status("not_operating", "1") } }
    assert_raises(SystemExit) { capture_io { set_status("resting", "1", BY: "human:tosin") } }
  end

  test "set_status refuses malformed ids, and records that aren't one plant" do
    site = Facility.create!(name: "Palisades", status: "operating", verification_status: "verified", verified_by: "human:tosin")
    other = Facility.create!(name: "Other Plant", status: "operating", verification_status: "verified", verified_by: "human:tosin")

    assert_raises(SystemExit) { capture_io { set_status("not_operating", "#{site.id}a", BY: "human:tosin", APPLY: "1") } }
    assert_raises(SystemExit) { capture_io { set_status("not_operating", "#{site.id} #{other.id}", BY: "human:tosin", APPLY: "1") } }
    assert other.reload.operating?
  end
end
