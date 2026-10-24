# Leads (#484): one admin list of everything that isn't a fact yet, so Data
# Quality can work it. A lead is a name of one kind (company, plant or other),
# with where it came up (searches that found nothing, news about a company we
# don't have, trade press, Enrich findings it couldn't source, new recipients
# waiting for their night, a pasted list), how often and when, and what was
# decided. Nothing publishes from it: a lead becomes facts only as pending
# claims through the usual path. Private to the admin (search text).
class CreateLeads < ActiveRecord::Migration[8.1]
  def change
    create_table :leads do |t|
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.string :kind, null: false, default: "other"
      t.jsonb :sources, null: false, default: []
      t.date :first_seen_on, null: false
      t.date :last_seen_on, null: false
      t.integer :seen_count, null: false, default: 1
      t.string :status, null: false, default: "new"
      t.text :reason
      t.string :record_type
      t.bigint :record_id
      t.text :note
      t.string :decided_by
      t.datetime :decided_at
      t.timestamps
    end
    add_index :leads, %i[kind normalized_name], unique: true
    add_index :leads, %i[status seen_count]
    add_check_constraint :leads, "kind IN ('company', 'plant', 'other')", name: "leads_kind_check"
    add_check_constraint :leads, "status IN ('new', 'researching', 'added', 'ignored')", name: "leads_status_check"
    add_check_constraint :leads, "seen_count >= 1", name: "leads_seen_count_check"
    add_check_constraint :leads, "status <> 'ignored' OR reason IS NOT NULL", name: "leads_ignored_reason_check"
    add_check_constraint :leads, "(record_type IS NULL) = (record_id IS NULL) AND (record_type IS NULL OR record_type IN ('Organization', 'Facility'))",
      name: "leads_record_check"
  end
end
