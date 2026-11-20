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
  ACTIONS = %w[edit_news propose_takeoff].freeze
  # Edits and proposals a day (DQ's own ask, 20 Nov).
  PER_DAY = 30
  # Text lengths (Infra): a headline fits Latest; a summary is a line or two.
  SUMMARY_MAX = 500

  def create
    rows = params.permit!.to_h.then { |all| all["actions"] || all["_json"] || [] }
    return render(json: { error: "send actions as a list of objects" }, status: :unprocessable_content) unless rows.is_a?(Array) && rows.all?(Hash)
    return render(json: { error: "send at most #{MAX_ROWS} actions at once" }, status: :unprocessable_content) if rows.size > MAX_ROWS

    # One request's take-off proposals are one set in Today.
    @batch = "dq-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3)}"
    # One news item per request (PM): a script bug can't rewrite many at once.
    if rows.count { |row| row["action"] == "edit_news" } > 1
      return render(json: { error: "edit one news item per request" }, status: :unprocessable_content)
    end

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
    def host(url) = (URI.parse(url).host.to_s.downcase.delete_prefix("www.") rescue "")

    # A host's registrable domain: its last two labels, or three under a
    # country's second level (co.uk, gov.au).
    def site(url)
      labels = host(url).split(".")
      keep = labels.size > 2 && labels[-1].length == 2 && %w[co com gov ac org net edu].include?(labels[-2]) ? 3 : 2
      labels.last(keep).join(".")
    end

    def allowed_source?(source, item)
      return false if site(source).blank?
      return true if site(source) == site(item.url) || host(source).match?(/\.(?:gov|mil|edu)\z/)

      companies = Organization.where(id: item.news_mentions.where(subject_type: "Organization").select(:subject_id)).where.not(website: [ nil, "" ]).pluck(:website)
      companies.any? { |website| site(website) == site(source) }
    end

    def done_today
      VerificationEvent.where(subject_type: "NewsItem", by: BY, created_at: Time.current.all_day).count +
        TakeoffProposal.where(proposed_by: BY, created_at: Time.current.all_day).count
    end

    def apply(row)
      id = row["id"].to_i
      return { id:, ok: false, error: "today's limit of #{PER_DAY} edits and proposals is reached" } if done_today >= PER_DAY

      return { id:, ok: false, error: "action must be one of #{ACTIONS.join(', ')}" } unless ACTIONS.include?(row["action"])

      source = row["source_url"].to_s.strip
      return { id:, ok: false, error: "give the source_url that shows the right text" } unless source.match?(%r{\Ahttps?://\S+\z})
      return propose_takeoff(row, id, source) if row["action"] == "propose_takeoff"

      values = row["values"].to_h
      return { id:, ok: false, error: "a summary is at most #{SUMMARY_MAX} characters" } if values["summary"].to_s.length > SUMMARY_MAX
      return { id:, ok: false, error: "a headline is at most #{NewsItem::HEADLINE_MAX} characters" } if values["headline"].to_s.squish.length > NewsItem::HEADLINE_MAX

      # The right text comes from the item's own page: the source is on its site (Infra).
      item = NewsItem.find_by(id:) or return { id:, ok: false, error: "no news item #{id}" }
      # The item's own site (an IR subdomain counts, DQ), a company it's about, or a government or university site (PM).
      unless allowed_source?(source, item)
        return { id:, ok: false, error: "source_url must be on the item's own site (#{site(item.url)}), a company it's about, or a .gov, .mil or .edu site" }
      end

      result = DataQuality::Review.edit_news(id:, by: BY, reason: row["reason"].to_s.strip, attributes: row["values"].to_h, context: { "source_url" => source })
      { id:, ok: result.ok?, error: result.errors.to_sentence.presence }.compact
    end

    # A Yes/No row in Today (#863): Tosin's Yes takes it off (Put back undoes it), his No keeps it.
    def propose_takeoff(row, id, source)
      type = row["type"].to_s
      return { id:, ok: false, error: "type must be one of #{TakeoffProposal::TYPES.join(', ')}" } unless TakeoffProposal::TYPES.include?(type)
      return { id:, ok: false, error: "give a reason" } if row["reason"].to_s.strip.empty?

      record = type.constantize.find_by(id:)
      return { id:, ok: false, error: "no #{type} #{id}" } unless record
      return { id:, ok: false, error: "it's #{record.verification_status}, not live" } unless record.verified?
      return { id:, ok: false, error: "already proposed" } if TakeoffProposal.pending.exists?(subject_type: type, subject_id: id)

      proposal = TakeoffProposal.create!(subject_type: type, subject_id: id, batch: @batch, reason: row["reason"].to_s.strip,
        source_url: source, quote: row["quote"].to_s.strip.presence, proposed_by: BY)
      { id:, ok: true, proposal_id: proposal.id, batch: @batch }
    end
end
