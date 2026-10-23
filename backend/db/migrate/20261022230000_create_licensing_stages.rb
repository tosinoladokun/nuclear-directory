# One stage a reactor project or plant has reached with the NRC (#379):
# pre-application, application accepted, construction permit, combined
# licence (Part 52), operating licence, restart under NRC review, design
# approval, withdrawn or denied. A fact like any other:
# verified by a human, sourced through evidence, audited.
#
# One row per stage reached, not one row updated: Hermes 1 has two rows
# (application accepted, then construction permit), so the history is the
# rows and the current stage is the latest one.
#
# The row goes on the record that holds the docket: the unit (or a
# one-record plant), or the developer for a design approval, which is why
# exactly one of the two is set.
class CreateLicensingStages < ActiveRecord::Migration[8.1]
  def change
    create_table :licensing_stages do |t|
      t.bigint :facility_id
      t.bigint :organization_id
      t.string :design_name
      t.string :stage, null: false
      t.string :nrc_docket, null: false
      t.date :effective_on, null: false
      t.date :expires_on
      t.decimal :confidence, precision: 3, scale: 2
      t.string :verification_status, default: "pending", null: false
      t.datetime :verified_at
      t.string :verified_by
      t.timestamps
    end

    add_foreign_key :licensing_stages, :facilities
    add_foreign_key :licensing_stages, :organizations

    add_index :licensing_stages, %i[facility_id nrc_docket stage], unique: true, name: "index_licensing_stages_on_facility"
    add_index :licensing_stages, %i[organization_id design_name stage], unique: true, name: "index_licensing_stages_on_organization"
    add_index :licensing_stages, :verification_status

    add_check_constraint :licensing_stages,
      "stage IN ('pre_application', 'application_accepted', 'construction_permit', 'combined_licence', 'operating_licence', 'restart_review', 'design_approval', 'withdrawn', 'denied')",
      name: "licensing_stages_stage_check"
    # Exactly one of the two: the record that holds the docket.
    add_check_constraint :licensing_stages, "(facility_id IS NULL) <> (organization_id IS NULL)", name: "licensing_stages_owner_check"
    # A design approval belongs to a design, and only to a developer: a
    # company, never a plant.
    add_check_constraint :licensing_stages,
      "stage <> 'design_approval' OR (organization_id IS NOT NULL AND design_name IS NOT NULL)",
      name: "licensing_stages_design_check"
    add_check_constraint :licensing_stages,
      "organization_id IS NULL OR stage = 'design_approval'",
      name: "licensing_stages_organization_stage_check"
    add_check_constraint :licensing_stages, "design_name IS NULL OR stage = 'design_approval'", name: "licensing_stages_design_name_check"
    add_check_constraint :licensing_stages, "expires_on IS NULL OR expires_on >= effective_on", name: "licensing_stages_dates_check"
    add_check_constraint :licensing_stages, "verification_status IN ('pending', 'verified', 'rejected', 'unpublished')",
      name: "licensing_stages_verification_status_check"
    add_check_constraint :licensing_stages, "confidence IS NULL OR confidence >= 0 AND confidence <= 1", name: "licensing_stages_confidence_check"
  end
end
