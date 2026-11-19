# Whether the lead-to-Create pipeline runs alone (#811): today's counts per stage, the problems found, two weeks.
class Admin::HealthController < Admin::BaseController
  def show
    @health = PipelineHealth.new
    @history = PipelineHealthSnapshot.where(on: 14.days.ago.to_date..).order(on: :desc)
  end
end
