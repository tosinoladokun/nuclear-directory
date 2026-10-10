# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_10_200000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "candidates", force: :cascade do |t|
    t.bigint "source_id", null: false
    t.bigint "crawl_run_id"
    t.string "kind", null: false
    t.jsonb "payload", default: {}, null: false
    t.text "quote"
    t.string "status", default: "new", null: false
    t.string "subject_type"
    t.bigint "subject_id"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["crawl_run_id"], name: "index_candidates_on_crawl_run_id"
    t.index ["source_id"], name: "index_candidates_on_source_id"
    t.index ["status", "kind"], name: "index_candidates_on_status_and_kind"
    t.index ["subject_type", "subject_id"], name: "index_candidates_on_subject"
    t.check_constraint "kind::text = ANY (ARRAY['organization'::character varying::text, 'organization_alias'::character varying::text, 'organization_role'::character varying::text, 'organization_technology'::character varying::text, 'facility'::character varying::text, 'relationship'::character varying::text, 'facility_relationship'::character varying::text])", name: "candidates_kind_check"
    t.check_constraint "status::text = ANY (ARRAY['new'::character varying::text, 'matched'::character varying::text, 'merged'::character varying::text, 'rejected'::character varying::text, 'needs_review'::character varying::text])", name: "candidates_status_check"
  end

  create_table "crawl_runs", force: :cascade do |t|
    t.string "stage", null: false
    t.string "source_kind"
    t.string "model"
    t.string "prompt_version"
    t.string "status", default: "running", null: false
    t.jsonb "stats", default: {}, null: false
    t.text "error"
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["stage", "started_at"], name: "index_crawl_runs_on_stage_and_started_at"
    t.check_constraint "stage::text = ANY (ARRAY['crawl'::character varying::text, 'extract'::character varying::text, 'match'::character varying::text, 'verify'::character varying::text])", name: "crawl_runs_stage_check"
    t.check_constraint "status::text = ANY (ARRAY['running'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text])", name: "crawl_runs_status_check"
  end

  create_table "evidence", force: :cascade do |t|
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.bigint "source_id", null: false
    t.text "quote"
    t.string "found_by", null: false
    t.bigint "crawl_run_id"
    t.decimal "confidence", precision: 3, scale: 2
    t.datetime "created_at", null: false
    t.index ["crawl_run_id"], name: "index_evidence_on_crawl_run_id"
    t.index ["source_id"], name: "index_evidence_on_source_id"
    t.index ["subject_type", "subject_id"], name: "index_evidence_on_subject"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "evidence_confidence_check"
    t.check_constraint "found_by::text = ANY (ARRAY['crawler'::character varying::text, 'verifier'::character varying::text, 'human'::character varying::text])", name: "evidence_found_by_check"
  end

  create_table "facilities", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.bigint "parent_id"
    t.string "facility_type"
    t.string "status"
    t.bigint "technology_id"
    t.string "reactor_type"
    t.decimal "capacity_mw", precision: 8, scale: 2
    t.string "nrc_docket"
    t.string "city"
    t.string "state"
    t.string "country_code", limit: 2, default: "US", null: false
    t.decimal "latitude", precision: 9, scale: 6
    t.decimal "longitude", precision: 9, scale: 6
    t.decimal "confidence", precision: 3, scale: 2
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verified_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["nrc_docket"], name: "index_facilities_on_nrc_docket", unique: true, where: "(nrc_docket IS NOT NULL)"
    t.index ["parent_id"], name: "index_facilities_on_parent_id"
    t.index ["slug"], name: "index_facilities_on_slug", unique: true
    t.index ["technology_id"], name: "index_facilities_on_technology_id"
    t.index ["verification_status"], name: "index_facilities_on_verification_status"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "facilities_confidence_check"
    t.check_constraint "facility_type::text = ANY (ARRAY['power_reactor'::character varying::text, 'research_reactor'::character varying::text, 'fuel_facility'::character varying::text, 'enrichment'::character varying::text, 'fusion_facility'::character varying::text, 'other'::character varying::text, 'uranium_mine'::character varying::text, 'mill'::character varying::text])", name: "facilities_facility_type_check"
    t.check_constraint "status::text = ANY (ARRAY['operating'::character varying::text, 'under_construction'::character varying::text, 'planned'::character varying::text, 'shut_down'::character varying::text, 'decommissioning'::character varying::text])", name: "facilities_status_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'rejected'::character varying::text])", name: "facilities_verification_status_check"
  end

  create_table "facility_relationships", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "facility_id", null: false
    t.string "relationship_type", null: false
    t.decimal "ownership_pct", precision: 5, scale: 2
    t.date "started_on"
    t.date "ended_on"
    t.decimal "confidence", precision: 3, scale: 2
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verified_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.index ["facility_id"], name: "index_facility_relationships_on_facility_id"
    t.index ["organization_id", "facility_id", "relationship_type"], name: "index_facility_relationships_uniqueness", unique: true
    t.index ["organization_id"], name: "index_facility_relationships_on_organization_id"
    t.index ["verification_status"], name: "index_facility_relationships_on_verification_status"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "facility_relationships_confidence_check"
    t.check_constraint "ownership_pct IS NULL OR ownership_pct >= 0::numeric AND ownership_pct <= 100::numeric", name: "facility_relationships_ownership_pct_check"
    t.check_constraint "relationship_type::text = ANY (ARRAY['owns'::character varying::text, 'operates'::character varying::text, 'vendor_for'::character varying::text, 'offtakes_from'::character varying::text])", name: "facility_relationships_relationship_type_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'rejected'::character varying::text])", name: "facility_relationships_verification_status_check"
  end

  create_table "organization_aliases", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "alias", null: false
    t.string "normalized_alias", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["normalized_alias"], name: "index_organization_aliases_on_normalized_alias", unique: true
    t.index ["organization_id"], name: "index_organization_aliases_on_organization_id"
  end

  create_table "organization_roles", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "role_id", null: false
    t.decimal "confidence", precision: 3, scale: 2
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verified_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "role_id"], name: "index_organization_roles_on_organization_id_and_role_id", unique: true
    t.index ["organization_id"], name: "index_organization_roles_on_organization_id"
    t.index ["role_id"], name: "index_organization_roles_on_role_id"
    t.index ["verification_status"], name: "index_organization_roles_on_verification_status"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "organization_roles_confidence_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'rejected'::character varying::text])", name: "organization_roles_verification_status_check"
  end

  create_table "organization_technologies", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "technology_id", null: false
    t.decimal "confidence", precision: 3, scale: 2
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verified_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "technology_id"], name: "idx_on_organization_id_technology_id_11af310cc8", unique: true
    t.index ["organization_id"], name: "index_organization_technologies_on_organization_id"
    t.index ["technology_id"], name: "index_organization_technologies_on_technology_id"
    t.index ["verification_status"], name: "index_organization_technologies_on_verification_status"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "organization_technologies_confidence_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'rejected'::character varying::text])", name: "organization_technologies_verification_status_check"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "legal_name"
    t.string "website"
    t.string "domain"
    t.text "description"
    t.string "hq_city"
    t.string "hq_state"
    t.string "country_code", limit: 2, default: "US"
    t.integer "founded_year"
    t.string "status", default: "active", null: false
    t.decimal "confidence", precision: 3, scale: 2
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verified_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_organizations_on_domain", unique: true
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
    t.index ["verification_status"], name: "index_organizations_on_verification_status"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "organizations_confidence_check"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'acquired'::character varying::text, 'defunct'::character varying::text])", name: "organizations_status_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'rejected'::character varying::text])", name: "organizations_verification_status_check"
  end

  create_table "relationships", force: :cascade do |t|
    t.bigint "from_organization_id", null: false
    t.bigint "to_organization_id", null: false
    t.string "relationship_type", null: false
    t.text "description"
    t.date "started_on"
    t.date "ended_on"
    t.decimal "confidence", precision: 3, scale: 2
    t.string "verification_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verified_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_organization_id", "to_organization_id", "relationship_type"], name: "index_relationships_uniqueness", unique: true
    t.index ["from_organization_id"], name: "index_relationships_on_from_organization_id"
    t.index ["to_organization_id"], name: "index_relationships_on_to_organization_id"
    t.index ["verification_status"], name: "index_relationships_on_verification_status"
    t.check_constraint "confidence IS NULL OR confidence >= 0::numeric AND confidence <= 1::numeric", name: "relationships_confidence_check"
    t.check_constraint "from_organization_id <> to_organization_id", name: "relationships_not_self_check"
    t.check_constraint "relationship_type::text = ANY (ARRAY['supplies'::character varying::text, 'invests_in'::character varying::text, 'funds'::character varying::text, 'offtake_with'::character varying::text, 'subsidiary_of'::character varying::text])", name: "relationships_relationship_type_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'rejected'::character varying::text])", name: "relationships_verification_status_check"
  end

  create_table "roles", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.bigint "parent_id"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_roles_on_key", unique: true
    t.index ["parent_id"], name: "index_roles_on_parent_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", null: false
    t.binary "value", null: false
    t.datetime "created_at", null: false
    t.bigint "key_hash", null: false
    t.integer "byte_size", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "sources", force: :cascade do |t|
    t.string "url", null: false
    t.string "domain"
    t.string "title"
    t.string "source_kind", null: false
    t.string "crawl_status", default: "pending", null: false
    t.text "status_reason"
    t.integer "http_status"
    t.datetime "fetched_at"
    t.string "content_sha256"
    t.text "content_text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "published_on"
    t.index ["domain"], name: "index_sources_on_domain"
    t.index ["source_kind"], name: "index_sources_on_source_kind"
    t.index ["url"], name: "index_sources_on_url", unique: true
    t.check_constraint "crawl_status::text = ANY (ARRAY['pending'::character varying::text, 'ok'::character varying::text, 'blocked'::character varying::text, 'needs_human'::character varying::text])", name: "sources_crawl_status_check"
  end

  create_table "technologies", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.bigint "parent_id"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_technologies_on_key", unique: true
    t.index ["parent_id"], name: "index_technologies_on_parent_id"
  end

  create_table "usage_counts", force: :cascade do |t|
    t.date "day", null: false
    t.string "event", null: false
    t.string "key", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day", "event", "key"], name: "index_usage_counts_on_day_and_event_and_key", unique: true
    t.index ["event", "day"], name: "index_usage_counts_on_event_and_day"
    t.check_constraint "count >= 0", name: "usage_counts_count_check"
    t.check_constraint "event::text = ANY (ARRAY['page_view'::character varying::text, 'search'::character varying::text, 'search_no_results'::character varying::text])", name: "usage_counts_event_check"
  end

  add_foreign_key "candidates", "crawl_runs"
  add_foreign_key "candidates", "sources"
  add_foreign_key "evidence", "crawl_runs"
  add_foreign_key "evidence", "sources"
  add_foreign_key "facilities", "facilities", column: "parent_id"
  add_foreign_key "facilities", "technologies"
  add_foreign_key "facility_relationships", "facilities"
  add_foreign_key "facility_relationships", "organizations"
  add_foreign_key "organization_aliases", "organizations"
  add_foreign_key "organization_roles", "organizations"
  add_foreign_key "organization_roles", "roles"
  add_foreign_key "organization_technologies", "organizations"
  add_foreign_key "organization_technologies", "technologies"
  add_foreign_key "relationships", "organizations", column: "from_organization_id"
  add_foreign_key "relationships", "organizations", column: "to_organization_id"
  add_foreign_key "roles", "roles", column: "parent_id"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "technologies", "technologies", column: "parent_id"
end
