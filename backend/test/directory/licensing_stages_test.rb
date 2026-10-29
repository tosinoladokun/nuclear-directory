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
      effective_on: Date.new(2023, 12, 14)).valid?, "a developer alone holds only a design approval or a project's early stage"
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
      nrc_docket: "1", effective_on: Date.new(2023, 12, 14)).valid?, "a design or project name is only on a developer's stage"
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

  test "an update locks the stage's plant before the stage, as a merge does, so the two can't deadlock" do
    id = write(verification: { status: "pending", by: "agent:pipeline" }).id
    locks = []
    callback = ->(*, payload) { locks << payload[:sql][/FROM "(\w+)"/, 1] if payload[:sql].include?("FOR UPDATE") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Directory::FactWriter.write(:licensing_stage, { id:, effective_on: "2023-12-15" }, verification: { status: "verified", by: BY },
        protect_human_verified: true)
    end

    assert_operator locks.index("facilities"), :<, locks.index("licensing_stages"), locks.inspect
  end

  test "a stage write locks its unit, never the site, so no unit-and-site lock order can deadlock with it" do
    unit = Facility.create!(name: "Low Id Unit", nrc_docket: "05009991", verification_status: "verified", verified_by: BY)
    site = Facility.create!(name: "High Id Site", verification_status: "verified", verified_by: BY)
    unit.update!(parent: site)
    id = write(stage(facility_id: unit.id, nrc_docket: "50-9991"), verification: { status: "pending", by: "agent:pipeline" }).id
    locked = []
    callback = ->(*, payload) { locked << payload[:binds]&.first&.value if payload[:sql].include?('FROM "facilities"') && payload[:sql].include?("FOR UPDATE") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Directory::FactWriter.write(:licensing_stage, { id:, effective_on: "2023-12-15" }, verification: { status: "verified", by: BY },
        protect_human_verified: true)
    end

    assert_equal [ unit.id ], locked.compact.uniq
  end

  test "a restart keeps the history: the original licence, the restart review and the restart approval" do
    by = { verification: { status: "verified", by: BY } }
    [ [ "operating_licence", "1974-02-01" ], [ "restart_review", "2025-01-15" ], [ "restart_approved", "2026-06-01" ] ].each do |name, on|
      assert write(stage(stage: name, effective_on: on), **by).ok?
    end

    assert_equal %w[operating_licence restart_review restart_approved], LicensingStage.where(facility: @unit).order(:effective_on).pluck(:stage)
    assert_equal Date.new(1974, 2, 1), LicensingStage.find_by(stage: "operating_licence").effective_on, "the original licence is untouched"
  end

  test "a stage moved by a merge between finding and locking it stops the write instead of locking out of order" do
    id = write(verification: { status: "pending", by: "agent:pipeline" }).id
    other = Facility.create!(name: "Hermes 1 duplicate", verification_status: "verified", verified_by: BY)
    # A merge commits between the owner lock and the stage lock.
    moved_by_merge = lambda do |record|
      LicensingStage.where(id: record.id).update_all(facility_id: other.id)
      { "facility_id" => record.facility_id }
    end
    original = Directory::FactWriter.instance_method(:lock_licensing_stage_owner)
    Directory::FactWriter.send(:define_method, :lock_licensing_stage_owner, &moved_by_merge)
    result = Directory::FactWriter.write(:licensing_stage, { id:, effective_on: "2023-12-15" }, verification: { status: "verified", by: BY },
      protect_human_verified: true)
    assert_match "moved to another record while it was being written", result.errors.join
  ensure
    if original
      Directory::FactWriter.send(:define_method, :lock_licensing_stage_owner, original)
      Directory::FactWriter.send(:private, :lock_licensing_stage_owner)
    end
  end

  test "a merge retires the duplicate stages it leaves behind, with the merge's actor" do
    plant = Facility.create!(name: "Acme Test Reactor", verification_status: "verified", verified_by: BY)
    duplicate = Facility.create!(name: "Acme Test Reactor Site", verification_status: "verified", verified_by: BY)
    write(stage(facility_id: plant.id, nrc_docket: "50-9998"), verification: { status: "verified", by: BY })
    left = write(stage(facility_id: duplicate.id, nrc_docket: "50-9998"), verification: { status: "verified", by: BY }).id

    assert Directory::FactWriter.merge_facility(from_id: duplicate.id, into_id: plant.id, by: BY).ok?

    stage = LicensingStage.find(left)
    assert stage.rejected?
    assert_equal BY, stage.verified_by
    assert_match "already has this", stage.verification_events.order(:id).last.reason
  end

  test "a developer holds a project's pre-application docket before its plant exists, once per docket (#650)" do
    pre = stage(facility_id: nil, organization_id: @developer.id, stage: "pre_application", nrc_docket: "99902038", effective_on: "2024-05-01")
    first = write(pre, quote: "Pre-application docket 99902038, Kairos Power")
    assert first.ok?, first.errors.inspect
    named = write(pre.merge(design_name: "KP-X"), quote: "Pre-application docket 99902038, Kairos Power")
    assert_equal first.id, named.id, "the same docket and stage is the same row, named or not"
    other = write(pre.merge(nrc_docket: "99902039"), quote: "Pre-application docket 99902039, Kairos Power")
    assert_not_equal first.id, other.id, "another docket is another project"
    assert write(stage(facility_id: nil, organization_id: @developer.id, stage: "withdrawn", nrc_docket: "99902038", effective_on: "2025-01-01"),
      quote: "Kairos Power withdrew docket 99902038").ok?

    assert_not LicensingStage.new(organization_id: @developer.id, stage: "construction_permit", nrc_docket: "99902038",
      effective_on: Date.new(2025, 1, 1)).valid?, "a later stage goes on the plant"
    error = assert_raises(ActiveRecord::RecordNotUnique) do
      LicensingStage.insert_all!([ { organization_id: @developer.id, stage: "pre_application", nrc_docket: "99902038",
        effective_on: Date.new(2024, 5, 1), verification_status: "pending", created_at: Time.current, updated_at: Time.current } ])
    end
    assert_match "index_licensing_stages_on_organization_docket", error.message
  end

  test "the database allows a licensing-stage claim (#650; the pipeline's handling is Backend's)" do
    now = Time.current
    assert_nothing_raised do
      Candidate.insert_all!([ { source_id: @nrc.id, kind: "licensing_stage", status: "new", quote: "Pre-application docket 99902038",
        payload: { "stage" => "pre_application", "nrc_docket" => "99902038" }, created_at: now, updated_at: now } ])
    end
  end
end
