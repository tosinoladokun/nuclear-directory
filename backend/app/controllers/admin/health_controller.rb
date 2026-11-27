# Whether the lead-to-Create pipeline runs alone (#811): today's counts per stage, the problems found, two weeks.
class Admin::HealthController < Admin::BaseController
  def show
    @health = PipelineHealth.new
    @history = PipelineHealthSnapshot.where(on: 14.days.ago.to_date..).order(on: :desc)
    @dq_pass = Switch.find_by(key: DqPass::KEY)
    @dq_pass_runs = CrawlRun.where(source_kind: DqPass::SOURCE_KIND).order(started_at: :desc).limit(7)
  end

  # Data Quality's daily pass (#998): on or off. Off stops every model call
  # it makes from the next run; a run already going finishes its current step.
  def dq_pass
    on = params[:on] == "1"
    Switch.set!(DqPass::KEY, on, by: actor)
    redirect_to admin_health_path, notice: on ? "Data Quality's pass is on. It runs each night at #{DqPass.run_time_pacific} Pacific." : "Data Quality's pass is off."
  end
end
