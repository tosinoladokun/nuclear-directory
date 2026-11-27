# Data Quality's trial of the pass's research (#998): start a dry run on up
# to MAX companies, then read each company's answer. Nothing is proposed.
#
#   POST /api/dq/pass_trials { "organization_ids": [356, 359, …] } => 202 { id: <run id> }
#   GET  /api/dq/pass_trials/:id => { status:, spent:, results: [{ id, name, outcome, website, role, … }] }
class Api::Dq::PassTrialsController < ActionController::API
  include Api::DqAgent
  MAX = 25

  def create
    ids = Array(params[:organization_ids]).map(&:to_i).select(&:positive?).uniq
    return render(json: { error: "give organization_ids: 1 to #{MAX} company ids" }, status: :unprocessable_content) unless ids.size.between?(1, MAX)

    run = CrawlRun.create!(source_kind: DqPass::TRIAL_KIND, stage: "verify", stats: { "organization_ids" => ids })
    DqPassTrialJob.perform_later(run.id, ids)
    render json: { id: run.id }, status: :accepted
  end

  def show
    run = CrawlRun.find_by(id: params[:id], source_kind: DqPass::TRIAL_KIND) or return render(json: { error: "no such trial" }, status: :not_found)

    render json: { status: run.status, error: run.error, spent: run.stats.dig("llm", "cost").to_f.round(4),
      by_model: run.stats.dig("llm", "by_model") || {}, results: run.stats["results"] || [] }
  end
end
