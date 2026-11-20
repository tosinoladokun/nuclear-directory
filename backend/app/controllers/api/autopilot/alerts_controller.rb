# Open autopilot alerts and those resolved in the last day, each with the session that fixes it (#811 "alert -> fix"),
# for the Mac poller that messages that session. Read only, with its own read token (Infra: never the DQ agent's,
# which can write): "Authorization: Bearer <token>" whose SHA-256 is AUTOPILOT_READ_TOKEN_DIGEST; without it, 404.
#
#   GET /api/autopilot/alerts => { alerts: [{ key, owner, title, opened_at, resolved_at }] }
class Api::Autopilot::AlertsController < ActionController::API
  rate_limit to: 60, within: 1.minute, store: Api::DqAgent::RATE_LIMIT_STORE, by: -> { "autopilot-read" },
    with: -> { head :too_many_requests, "Retry-After" => "60" }
  before_action :require_reader
  MAX = 200

  def index
    rows = AutopilotAlert.where(resolved_at: nil).or(AutopilotAlert.where(resolved_at: 1.day.ago..)).order(:opened_at).limit(MAX)
    render json: { alerts: rows.map { |alert|
      { key: alert.key, owner: ::Autopilot::Owners.for(alert.key), title: alert.title, opened_at: alert.opened_at&.iso8601,
        resolved_at: alert.resolved_at&.iso8601 }
    } }
  end

  private
    def require_reader
      digest = ENV["AUTOPILOT_READ_TOKEN_DIGEST"].to_s.strip.downcase
      return head(:not_found) unless digest.match?(/\A\h{64}\z/)

      presented = request.authorization.to_s[/\ABearer (\S+)\z/, 1].to_s
      ok = ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(presented), digest)
      render(json: { error: "unauthorized" }, status: :unauthorized) unless ok && presented.present?
    end
end
