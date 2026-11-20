# The nightly checker's shadow verdicts (#776) for Data Quality to compare with its own. Read only.
#
#   GET /api/dq/checker?since=2026-11-20[&after=<id>]
#   => { counts: { "website" => { "approve" => 3, "unsure" => 9 } }, verdicts: [{ id, candidate_id, field, … }], next_after: id or null }
# At most MAX verdicts a page; next_after asks for the next page (counts always cover the whole period).
class Api::Dq::CheckerController < ActionController::API
  include Api::DqAgent
  MAX = 500

  def index
    since = (Date.iso8601(params[:since].to_s) rescue 1.day.ago.to_date)
    scope = CheckerVerdict.where(created_at: since.beginning_of_day..)
    counts = scope.group(:field, :verdict).count.each_with_object({}) { |((field, verdict), n), all| (all[field] ||= {})[verdict] = n }
    rows = scope.where(id: params[:after].to_i + 1..).order(:id).limit(MAX + 1).to_a
    more = rows.size > MAX
    verdicts = rows.first(MAX).map do |row|
      { id: row.id, candidate_id: row.candidate_id, field: row.field, verdict: row.verdict, reason: row.reason,
        confidence: row.confidence&.to_f, model: row.model, escalated: row.escalated, at: row.created_at.iso8601 }
    end
    render json: { counts:, verdicts:, next_after: (verdicts.last[:id] if more) }
  end
end
