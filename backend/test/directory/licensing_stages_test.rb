require "test_helper"

# Licensing stages (#379): the NRC stage a reactor project or plant has
# reached, its docket and its date, from an NRC record and nothing else.
class Directory::LicensingStagesTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @developer = Organization.create!(name: "Kairos Power", verification_status: "verified", verified_by: BY)
    @site = Facility.create!(name: "Hermes", verification_status: "verified", verified_by: BY)
    @unit = Facility.create!(name: "Hermes 1", parent: @site, nrc_docket: "05007513",
      verification_status: "verified", verified_by: BY)
    @nrc = sources(:nrc)
    @press = sources(:press_release)
  end

  def stage(**attributes)
    { facility_id: @unit.id, stage: "construction_permit", nrc_docket: "50-7513", effective_on: "2023-12-14" }.merge(attributes)
  end

  def write(attributes = stage, source: @nrc, quote: "NRC issued a construction permit to Hermes 1", **options)
    Directory::FactWriter.write(:licensing_stage, attributes,
      evidence: [ { source_id: source.id, quote:, found_by: "human", confidence: 1 } ],
      **options)
  end

  test "a stage is written with its evidence, and found again by its unit, docket and stage" do
    result = write
    assert result.ok?, result.errors.inspect

    row = LicensingStage.find(result.id)
    assert_equal [ @unit, "05007513", Date.new(2023, 12, 14) ], [ row.facility, row.nrc_docket, row.effective_on ]
    assert_equal [ "NRC issued a construction permit to Hermes 1" ], row.evidence.pluck(:quote)

    again = write
    assert_equal result.id, again.id
    assert_equal 1, LicensingStage.count
  end

  test "the docket is stored the way the directory stores it" do
    assert_equal "05007513", LicensingStage.normalize_docket("50-7513")
    assert_equal "05000302", LicensingStage.normalize_docket("50-302")
    assert_equal "05007513", LicensingStage.normalize_docket(" 05007513 ")
    assert_equal "TSR-13-141", LicensingStage.normalize_docket("TSR-13-141")
  end

  test "a stage needs exactly one record: a unit or a developer" do
    assert LicensingStage.new(facility_id: @unit.id, stage: "construction_permit", nrc_docket: "1",
      effective_on: Date.new(2023, 12, 14)).valid?, "a unit alone is enough"
    assert_not LicensingStage.new(organization_id: @developer.id, stage: "construction_permit", nrc_docket: "1",
      effective_on: Date.new(2023, 12, 14)).valid?, "a developer alone is only for a design approval"
    assert_not LicensingStage.new(facility_id: @unit.id, organization_id: @developer.id, stage: "construction_permit",
      nrc_docket: "1", effective_on: Date.new(2023, 12, 14)).valid?, "not both"
  end

  test "a design approval belongs to a developer and names its design" do
    approval = LicensingStage.new(organization_id: @developer.id, design_name: "US460", stage: "design_approval",
      nrc_docket: "15-913", effective_on: Date.new(2025, 1, 1))

    assert approval.valid?, approval.errors.full_messages.inspect
    assert_not LicensingStage.new(organization_id: @developer.id, stage: "design_approval", nrc_docket: "15-913",
      effective_on: Date.new(2025, 1, 1)).valid?, "a design approval needs its design"
    assert_not LicensingStage.new(facility_id: @unit.id, design_name: "US460", stage: "construction_permit",
      nrc_docket: "1", effective_on: Date.new(2023, 12, 14)).valid?, "a design name is only for a design approval"
  end

  test "the stage is one of the seven, and the dates are in order" do
    assert_not LicensingStage.new(facility_id: @unit.id, stage: "approved", nrc_docket: "1", effective_on: Date.new(2023, 12, 14)).valid?
    assert_not LicensingStage.new(facility_id: @unit.id, stage: "operating_licence", nrc_docket: "1",
      effective_on: Date.new(2023, 12, 14), expires_on: Date.new(2020, 1, 1)).valid?
  end

  # A raw insert, in its own savepoint, so a refused row doesn't abort the
  # test's transaction.
  def raw_insert(attributes)
    ActiveRecord::Base.transaction(requires_new: true) do
      LicensingStage.insert_all!([ attributes.merge(created_at: Time.current, updated_at: Time.current) ])
    end
  end

  test "the database refuses a bad stage, whatever the model says" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      raw_insert(facility_id: @unit.id, organization_id: @developer.id, design_name: "US460",
        stage: "design_approval", nrc_docket: "05007513", effective_on: Date.new(2023, 12, 14))
    end
    assert_match "licensing_stages_owner_check", error.message

    error = assert_raises(ActiveRecord::StatementInvalid) do
      raw_insert(facility_id: @unit.id, stage: "approved", nrc_docket: "05007513", effective_on: Date.new(2023, 12, 14))
    end
    assert_match "licensing_stages_stage_check", error.message

    error = assert_raises(ActiveRecord::StatementInvalid) do
      raw_insert(organization_id: @developer.id, stage: "construction_permit", nrc_docket: "05007513",
        effective_on: Date.new(2023, 12, 14))
    end
    assert_match "licensing_stages_organization_stage_check", error.message
  end

  test "a stage is verified only from an NRC record" do
    result = write(source: @press, verification: { status: "verified", by: BY })

    assert_not result.ok?
    assert_match "needs an NRC record", result.errors.join
    assert_equal 0, LicensingStage.count, "nothing was written"
  end

  test "a stage from a press release can still be a lead, pending" do
    result = write(source: @press, verification: { status: "pending", by: BY })

    assert result.ok?, result.errors.inspect
    assert_equal "pending", LicensingStage.find(result.id).verification_status
  end

  test "an NRC notice in the Federal Register is an NRC record" do
    notice = Source.create!(url: "https://www.federalregister.gov/documents/2026/05/16/2025-07729/nuclear-regulatory-commission",
      domain: "federalregister.gov", source_kind: "web_page")

    result = write(source: notice, verification: { status: "verified", by: BY })

    assert result.ok?, result.errors.inspect
    assert_equal "verified", LicensingStage.find(result.id).verification_status
  end

  test "a press release is never an NRC record, even when its quote names the NRC" do
    result = write(source: @press, verification: { status: "verified", by: BY })

    assert_not result.ok?
    assert_match "needs an NRC record", result.errors.join
  end

  test "a government notice that doesn't name the NRC is not an NRC record" do
    notice = Source.create!(url: "https://www.govinfo.gov/content/pkg/FR-2025-05-16/html/2025-07729.htm",
      domain: "govinfo.gov", source_kind: "web_page")

    result = write(source: notice, quote: "The applicant filed an application for a construction permit.",
      verification: { status: "verified", by: BY })

    assert_not result.ok?
    assert_match "needs an NRC record", result.errors.join
  end

  test "on govinfo.gov only a Federal Register package counts, never the Congressional Record or a hearing" do
    record = Source.create!(url: "https://www.govinfo.gov/content/pkg/CREC-2025-05-16/html/CREC-2025-05-16-pt1-PgS1.htm",
      domain: "govinfo.gov", source_kind: "web_page")
    hearing = Source.create!(url: "https://www.govinfo.gov/content/pkg/CHRG-118shrg123/html/CHRG-118shrg123.htm",
      domain: "govinfo.gov", source_kind: "web_page")

    [ record, hearing ].each do |document|
      result = write(source: document, verification: { status: "verified", by: BY })
      assert_match "needs an NRC record", result.errors.join, document.url
    end
    assert_not LicensingStage.nrc_record?(domain: "govinfo.gov", url: record.url, quote: "the NRC issued a permit")
  end

  test "a government notice whose quote names the NRC is an NRC record" do
    notice = Source.create!(url: "https://www.govinfo.gov/content/pkg/FR-2025-05-16/html/2025-07729.htm",
      domain: "govinfo.gov", source_kind: "web_page")

    result = write(source: notice, verification: { status: "verified", by: BY })

    assert result.ok?, result.errors.inspect
  end

  test "a stage is public only when it's verified, its unit is published and an NRC record is behind it" do
    write(verification: { status: "verified", by: BY })
    assert_equal 1, Directory::Lookup.licensing_stages(facility_id: @unit.id).size

    write(stage(stage: "application_accepted"), source: @press, verification: { status: "verified", by: BY })
    assert_equal 1, Directory::Lookup.licensing_stages(facility_id: @unit.id).size, "a stage with no NRC record is never public"

    @unit.reject!(by: BY)
    assert_empty Directory::Lookup.licensing_stages(facility_id: @unit.id)
  end

  test "the stages of a unit read newest first, and the current one is the latest" do
    write(stage(stage: "application_accepted", effective_on: "2021-05-12"), verification: { status: "verified", by: BY })
    write(verification: { status: "verified", by: BY })

    stages = Directory::Lookup.licensing_stages(facility_id: @unit.id)
    assert_equal [ "construction_permit", "application_accepted" ], stages.map(&:stage)
    assert_equal "Construction permit", stages.first.stage_label
    assert_equal "construction_permit", Directory::Lookup.current_licensing_stage(facility_id: @unit.id).stage
  end

  test "the read gives plain values with the stage's sources" do
    write(verification: { status: "verified", by: BY })

    ref = Directory::Lookup.licensing_stages(facility_id: @unit.id).sole
    assert_equal [ @nrc.url ], ref.source_urls
    assert_equal "05007513", ref.nrc_docket
  end

  test "a design approval is read from the developer" do
    approval = { organization_id: @developer.id, design_name: "US460", stage: "design_approval",
      nrc_docket: "15-913", effective_on: "2025-01-01" }

    assert write(approval, verification: { status: "verified", by: BY }).ok?
    assert_equal [ "design_approval" ], Directory::Lookup.licensing_stages(organization_id: @developer.id).map(&:stage)
  end

  test "no automated stage under a rejected plant" do
    @unit.reject!(by: BY)

    result = write(verification: { status: "verified", by: BY }, protect_human_verified: true)

    assert_not result.ok?
    assert_match "no stage added", result.errors.join
    assert_equal 0, LicensingStage.count
  end

  test "no automated stage on an open unit whose site was rejected" do
    @site.reject!(by: BY)

    result = write(verification: { status: "verified", by: BY }, protect_human_verified: true)

    assert_match "Hermes was rejected", result.errors.join
    assert_equal 0, LicensingStage.count
  end

  test "a pending stage can still be retired after its plant is closed" do
    id = write(verification: { status: "pending", by: "agent:pipeline" }).id
    @unit.reject!(by: BY)

    result = Directory::FactWriter.write(:licensing_stage, { id: }, verification: { status: "rejected", by: "agent:pipeline" },
      protect_human_verified: true)

    assert result.ok?, result.errors.inspect
    assert LicensingStage.find(id).rejected?
  end

  test "the read never shows a verified stage with no NRC record behind it, however it was verified" do
    id = write(source: @press, verification: { status: "pending", by: BY }).id
    LicensingStage.find(id).verify!(by: BY) # past FactWriter's check, straight on the model

    assert LicensingStage.find(id).verified?
    assert_empty Directory::Lookup.licensing_stages(facility_id: @unit.id)
  end

  test "a plant merge moves the plant's own stages, keeps one the kept plant has, and the preview counts them" do
    plant = Facility.create!(name: "Acme Test Reactor", verification_status: "verified", verified_by: BY)
    duplicate = Facility.create!(name: "Acme Test Reactor Site", verification_status: "verified", verified_by: BY)
    assert write(stage(facility_id: duplicate.id, nrc_docket: "50-9999"), verification: { status: "verified", by: BY }).ok?
    assert write(stage(facility_id: plant.id, nrc_docket: "50-9998"), verification: { status: "verified", by: BY }).ok?
    kept_behind = write(stage(facility_id: duplicate.id, nrc_docket: "50-9998"), verification: { status: "verified", by: BY })

    _, preview = Directory::FactWriter.merge_preview(type: "Facility", from_id: duplicate.id, into_id: plant.id)
    assert Directory::FactWriter.merge_facility(from_id: duplicate.id, into_id: plant.id, by: BY).ok?

    assert_equal %w[05009998 05009999], LicensingStage.where(facility_id: plant.id).pluck(:nrc_docket).sort
    assert_equal duplicate.id, LicensingStage.find(kept_behind.id).facility_id, "the kept plant already has that docket at that stage"
    assert_match "1 licensing stage", preview
    assert_equal preview, duplicate.verification_events.order(:id).last.reason[/Moved: (.*)\z/, 1]
  end

  test "a stage needs one of the two records" do
    assert_match "needs a facility or an organization", write(stage(facility_id: nil)).errors.join
  end

  def approval(organization, design: "US460")
    { organization_id: organization.id, design_name: design, stage: "design_approval", nrc_docket: "15-913", effective_on: "2025-01-01" }
  end

  test "a company merge moves its design approvals, and the preview counts them" do
    duplicate = Organization.create!(name: "Kairos Power LLC Holdings", verification_status: "verified", verified_by: BY)
    assert write(approval(duplicate), verification: { status: "verified", by: BY }).ok?

    _, preview = Directory::FactWriter.merge_preview(type: "Organization", from_id: duplicate.id, into_id: @developer.id)
    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @developer.id, by: BY).ok?

    assert_equal [ @developer.id ], LicensingStage.pluck(:organization_id)
    assert_equal [ "design_approval" ], Directory::Lookup.licensing_stages(organization_id: @developer.id).map(&:stage)
    assert_match "1 licensing stage", preview
    assert_equal preview, duplicate.verification_events.order(:id).last.reason[/Moved: (.*)\z/, 1]
  end

  test "a design approval the kept company already has stays behind" do
    duplicate = Organization.create!(name: "Kairos Power LLC Holdings", verification_status: "verified", verified_by: BY)
    assert write(approval(@developer), verification: { status: "verified", by: BY }).ok?
    kept_behind = write(approval(duplicate), verification: { status: "verified", by: BY })

    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @developer.id, by: BY).ok?

    assert_equal duplicate.id, LicensingStage.find(kept_behind.id).organization_id
    assert_equal 1, LicensingStage.where(organization_id: @developer.id).count
  end
end
