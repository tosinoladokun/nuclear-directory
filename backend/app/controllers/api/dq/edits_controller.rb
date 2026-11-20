# Data Quality's text fixes (#863 part 2): a news item's headline, summary
# or date, without a data-step PR. Edit only: nothing is created, deleted or
# taken off here (take-offs stay Tosin's Yes/No in the inbox). Each edit needs
# a reason and the source that shows the right text; it is recorded in the
# item's history as agent:data-quality, the item stays public with its
# approver unchanged, and it can be undone.
#
#   POST /api/dq/edits       [{ "action": "edit_news", "id": 70, "values": { "headline": "…" },
#                               "reason": "…", "source_url": "https://…" }, …] (or { "actions": [...] })
#                            => { "results": [{ "id", "ok", "error" }] }
#   POST /api/dq/edits/undo  { "id": 70 } => { "ok": true } or { "ok": false, "error": "…" }
#   GET  /api/dq/edits       Data Quality's edits of the last 7 days (for the daily summary)
class Api::Dq::EditsController < ActionController::API
  include Api::DqAgent

  BY = "agent:data-quality".freeze
  MAX_ROWS = 50
  ACTIONS = %w[edit_news].freeze

  def create
    rows = params.permit!.to_h.then { |all| all["actions"] || all["_json"] || [] }
    return render(json: { error: "send actions as a list of objects" }, status: :unprocessable_content) unless rows.is_a?(Array) && rows.all?(Hash)
    return render(json: { error: "send at most #{MAX_ROWS} actions at once" }, status: :unprocessable_content) if rows.size > MAX_ROWS

    render json: { results: rows.map { |row| apply(row) } }
  end

  def undo
    result = DataQuality::Review.undo_news_edit(id: params[:id].to_i, by: BY)
    render json: result.ok? ? { ok: true } : { ok: false, error: result.errors.to_sentence }
  end

  def index
    events = VerificationEvent.where(subject_type: "NewsItem", by: BY, created_at: 7.days.ago..).order(id: :desc).limit(200)
    render json: { edits: events.map { |event| { id: event.subject_id, at: event.created_at, reason: event.reason, source_url: event.context["source_url"], changed: event.changed_values } } }
  end

  private
    def apply(row)
      id = row["id"].to_i
      return { id:, ok: false, error: "action must be one of #{ACTIONS.join(', ')}" } unless ACTIONS.include?(row["action"])

      source = row["source_url"].to_s.strip
      return { id:, ok: false, error: "give the source_url that shows the right text" } unless source.match?(%r{\Ahttps?://\S+\z})

      result = DataQuality::Review.edit_news(id:, by: BY, reason: row["reason"].to_s.strip, attributes: row["values"].to_h, context: { "source_url" => source })
      { id:, ok: result.ok?, error: result.errors.to_sentence.presence }.compact
    end
end
