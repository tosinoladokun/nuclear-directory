# A developer holds a project's early stages before the plant exists (#650):
# a pre-application docket (NRC's 999xxxxx project dockets), or its
# withdrawal, sits on the company, as a design approval does. design_name is
# the design's or the project's name when the record gives one. Once the
# project is a plant in the directory, its stages go on the plant.
# One row per developer, docket and stage, so the reader's repeats update it.
class DeveloperLicensingStages < ActiveRecord::Migration[8.1]
  ON_COMPANY = "('design_approval', 'pre_application', 'withdrawn')"

  def up
    remove_check_constraint :licensing_stages, name: "licensing_stages_organization_stage_check"
    add_check_constraint :licensing_stages, "organization_id IS NULL OR stage IN #{ON_COMPANY}",
      name: "licensing_stages_organization_stage_check"
    remove_check_constraint :licensing_stages, name: "licensing_stages_design_name_check"
    add_check_constraint :licensing_stages, "design_name IS NULL OR organization_id IS NOT NULL", name: "licensing_stages_design_name_check"
    add_index :licensing_stages, %i[organization_id nrc_docket stage], unique: true, where: "organization_id IS NOT NULL",
      name: "index_licensing_stages_on_organization_docket"
  end

  def down
    if select_value("SELECT 1 FROM licensing_stages WHERE organization_id IS NOT NULL AND stage <> 'design_approval' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "a developer holds a pre-application or withdrawn stage; keep this migration in"
    end

    remove_index :licensing_stages, name: "index_licensing_stages_on_organization_docket"
    remove_check_constraint :licensing_stages, name: "licensing_stages_design_name_check"
    add_check_constraint :licensing_stages, "design_name IS NULL OR stage = 'design_approval'", name: "licensing_stages_design_name_check"
    remove_check_constraint :licensing_stages, name: "licensing_stages_organization_stage_check"
    add_check_constraint :licensing_stages, "organization_id IS NULL OR stage = 'design_approval'", name: "licensing_stages_organization_stage_check"
  end
end
