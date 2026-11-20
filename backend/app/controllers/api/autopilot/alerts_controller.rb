# Open autopilot alerts and those resolved in the last day, each with the session that fixes it (#811 "alert -> fix"),
# for the Mac poller that messages that session. Read only, with the DQ agent token.
#
#   GET /api/autopilot/alerts => { alerts: [{ key, owner, title, opened_at, resolved_at }] }
class Api::Autopilot::AlertsController < ActionController::API
  include Api::DqAgent

  def index
    rows = AutopilotAlert.where(resolved_at: nil).or(AutopilotAlert.where(resolved_at: 1.day.ago..)).order(:opened_at)
    render json: { alerts: rows.map { |alert|
      { key: alert.key, owner: ::Autopilot::Owners.for(alert.key), title: alert.title, opened_at: alert.opened_at&.iso8601,
        resolved_at: alert.resolved_at&.iso8601 }
    } }
  end
end
