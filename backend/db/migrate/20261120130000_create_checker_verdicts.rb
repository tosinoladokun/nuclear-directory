# The nightly checker's verdicts in shadow (#776): kept here only, never recorded on the claim, until DQ
# compares them with its own for two weeks and a field is switched on.
class CreateCheckerVerdicts < ActiveRecord::Migration[8.1]
  def change
    create_table :checker_verdicts do |t|
      t.references :candidate, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :crawl_run_id
      t.string :field, null: false
      t.string :verdict, null: false
      t.string :reason, null: false
      t.decimal :confidence, precision: 3, scale: 2
      t.string :model
      t.boolean :escalated, null: false, default: false
      t.string :prompt_version, null: false
      t.datetime :created_at, null: false
      t.index %i[candidate_id prompt_version], unique: true
      t.index :created_at
      t.check_constraint "verdict IN ('approve', 'reject', 'unsure')", name: "checker_verdicts_verdict_check"
    end
  end
end
