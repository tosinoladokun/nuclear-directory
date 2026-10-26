# Data Quality's agent settles company claims here (#548, option a), so
# Tosin never handles matching: same_as, new, subsidiary_of and close, each
# recorded with its reason and undoable (DataQuality::Matching). Nothing it
# does publishes or verifies.
#
# Auth: "Authorization: Bearer <token>", whose SHA-256 must equal
# DQ_AGENT_TOKEN_DIGEST. Without that variable the endpoint doesn't exist.
#
#   POST /api/dq/matching       [{ "id": 12, "action": "same_as", "target": 40, "reason": "…" }, …]
#                               (or { "actions": [...] }) => { "results": [{ id, ok, error, created_ids }] }
#   POST /api/dq/matching/undo  { "action_id": 7 } => { "ok": true } or { "ok": false, "error": "…" }
#   GET  /api/dq/matching       the last 100 actions
class Api::Dq::MatchingController < ActionController::API
  MAX_ROWS = 100
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  before_action :require_agent
  rate_limit to: 60, within: 1.minute, store: RATE_LIMIT_STORE, by: -> { "dq-agent" },
    with: -> { head :too_many_requests, "Retry-After" => "60" }

  def create
    rows = params.permit!.to_h.then { |all| all["actions"] || all["_json"] || [] }
    return render(json: { error: "send at most #{MAX_ROWS} actions at once" }, status: :unprocessable_content) if rows.size > MAX_ROWS

    render json: { results: DataQuality::Matching.apply(rows).map(&:to_h) }
  end

  def undo
    error = DataQuality::Matching.undo(params[:action_id].to_i)
    render json: { ok: error.nil?, error: }.compact, status: error ? :unprocessable_content : :ok
  end

  def index
    render json: { actions: DqAction.order(id: :desc).limit(100).as_json(only: %i[id candidate_id action target reason created undone_at created_at]) }
  end

  private
    def require_agent
      digest = ENV["DQ_AGENT_TOKEN_DIGEST"].to_s
      return head(:not_found) if digest.blank?

      token = request.authorization.to_s.delete_prefix("Bearer ")
      head :unauthorized unless token.present? && ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(token), digest)
    end
end
