# Data Quality's trial of the pass's research (#998): start a dry run on up
# to MAX companies, then read each company's answer. Nothing is proposed.
#
#   POST /api/dq/pass_trials { "organization_ids": [356, 359, …] } => 202 { id: "<token>" }
#   GET  /api/dq/pass_trials/<token> => { status: "queued" | "running" | "succeeded" | "failed", spent:, results: [...] }
class Api::Dq::PassTrialsController < ActionController::API
  include Api::DqAgent
  MAX = 25
  TOKEN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def create
    ids = Array(params[:organization_ids]).map(&:to_i).select(&:positive?).uniq
    return render(json: { error: "give organization_ids: 1 to #{MAX} company ids" }, status: :unprocessable_content) unless ids.size.between?(1, MAX)

    token = SecureRandom.uuid
    DqPassTrialJob.perform_later(token, ids)
    render json: { id: token }, status: :accepted
  end

  def show
    token = params[:id].to_s
    return render(json: { error: "no such trial" }, status: :not_found) unless token.match?(TOKEN)

    run = CrawlRun.where(source_kind: DqPass::TRIAL_KIND).where("stats->>'trial' = ?", token).order(:id).last
    return render(json: { status: "queued", results: [] }) unless run

    render json: { status: run.status, error: run.error, spent: run.stats.dig("llm", "cost").to_f.round(4),
      by_model: run.stats.dig("llm", "by_model") || {}, results: run.stats["results"] || [] }
  end
end
