# Data Quality's call on a claim (#306): approve or reject, with its reason,
# who entered it and when, and a digest of the claim as it read then, so a
# claim that changed afterwards isn't accepted on an old call. A
# recommendation decides nothing: a person's "Accept" does.
class AddDataQualityRecommendationToCandidates < ActiveRecord::Migration[8.1]
  def change
    change_table :candidates, bulk: true do |t|
      t.string :dq_recommendation
      t.text :dq_reason
      t.string :dq_by
      t.datetime :dq_at
      t.string :dq_payload_sha256
    end
    add_check_constraint :candidates, "dq_recommendation IN ('approve', 'reject')", name: "candidates_dq_recommendation_check"
    add_index :candidates, :dq_recommendation, where: "dq_recommendation IS NOT NULL"
  end
end
