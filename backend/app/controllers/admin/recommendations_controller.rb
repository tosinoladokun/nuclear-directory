# Data Quality's recommendations (#306): Tosin pastes Data Quality's list
# (one call per claim), sees exactly which claims Accept will decide and
# which are left for him and why, then accepts them in one click. Each is
# recorded as his decision, "Accepted Data Quality's recommendation: …".
class Admin::RecommendationsController < Admin::BaseController
  def show
    @plan = DataQuality::Recommendations.plan
  end

  # Records the pasted list (decides nothing). All of it read: back to the
  # plan (a redirect, which Turbo follows). Lines it couldn't add: the plan
  # with them listed, and the list kept in the box to fix.
  def create
    recorded = DataQuality::Recommendations.record(params[:list].to_s, by: actor)
    if recorded.errors.empty?
      flash[:notice] = "Added #{helpers.pluralize(recorded.recorded, 'recommendation')}. Nothing is decided until you accept."
      return redirect_after admin_recommendations_path
    end

    @plan = DataQuality::Recommendations.plan
    @recorded = recorded.recorded
    @errors = recorded.errors
    render :show, status: :unprocessable_content
  end

  # Only the list the page showed: if anything was added, decided or changed
  # since, nothing is accepted.
  def accept
    plan = DataQuality::Recommendations.plan
    if plan.accept.empty?
      flash[:alert] = "Nothing to accept."
    elsif params[:shown] != plan.fingerprint
      flash[:alert] = "The list changed since you opened it, so nothing was accepted. Check it and try again."
    else
      results = DataQuality::Recommendations.accept(plan.accept, by: actor)
      done, failed = results.partition(&:ok?)
      flash[:notice] = "Accepted #{helpers.pluralize(done.size, 'recommendation')}." if done.any?
      flash[:alert] = failed.map { |result| "Claim #{result.candidate_id}: #{result.errors.to_sentence}" }.join(" ") if failed.any?
    end
    redirect_after admin_recommendations_path
  end
end
