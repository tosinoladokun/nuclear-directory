# The pipeline's health for Data Quality's morning check (#811): today's counts and problems, and the last two weeks.
#
#   GET /api/dq/health => { counts: {…}, problems: […], history: [{ on, counts, problems }] }
class Api::Dq::HealthController < ActionController::API
  include Api::DqAgent

  def show
    health = PipelineHealth.new
    history = PipelineHealthSnapshot.where(on: 14.days.ago.to_date..).order(on: :desc).map { |row| row.slice(:on, :counts, :problems) }
    render json: { counts: health.counts, problems: health.problems, history: }
  end
end
