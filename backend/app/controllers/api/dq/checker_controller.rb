# The nightly checker's shadow verdicts (#776) for Data Quality to compare with its own. Read only.
#
#   GET /api/dq/checker?since=2026-11-20
#   => { counts: { "website" => { "approve" => 3, "unsure" => 9 } }, verdicts: [{ candidate_id, field, verdict, reason, confidence, model, escalated, at }] }
class Api::Dq::CheckerController < ActionController::API
  include Api::DqAgent
  MAX = 500

  def index
    since = (Date.iso8601(params[:since].to_s) rescue 1.day.ago.to_date)
    scope = CheckerVerdict.where(created_at: since.beginning_of_day..)
    counts = scope.group(:field, :verdict).count.each_with_object({}) { |((field, verdict), n), all| (all[field] ||= {})[verdict] = n }
    verdicts = scope.order(:id).limit(MAX).map do |row|
      { candidate_id: row.candidate_id, field: row.field, verdict: row.verdict, reason: row.reason,
        confidence: row.confidence&.to_f, model: row.model, escalated: row.escalated, at: row.created_at.iso8601 }
    end
    render json: { counts:, verdicts: }
  end
end
