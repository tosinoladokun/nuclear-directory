# Today as Tosin's inbox (#548): Create, Approve or No on what's new, a
# change to something already there, and a week of his decisions with Undo
# for a No. Nothing goes live without his Yes; every decision is checked again
# under its locks, as everywhere else.
class Admin::InboxController < Admin::BaseController
  def show
    @inbox = OwnerInbox.new
  end

  # Yes or No on one fact, with its copies from other pages.
  def decide
    ids = Array(params[:ids]).map(&:to_i).presence || [ params[:candidate_id].to_i ]
    results = if params[:decision] == "yes"
      DataQuality::Review.approve(ids, by: actor, reason: "Approved in Today")
    else
      DataQuality::Review.reject(ids, by: actor, reason: "Said no in Today")
    end
    stopped = results.reject(&:ok?)
    if stopped.empty?
      flash[:notice] = params[:decision] == "yes" ? "Done. It's live." : "Said no."
    else
      flash[:alert] = "Not done: #{stopped.flat_map(&:errors).uniq.to_sentence}."
    end
    redirect_to admin_inbox_path
  end

  # Yes to every item Data Quality checked that the page showed, each checked
  # again first: still Data Quality's approve, unchanged since it looked.
  def yes_all
    shown = Array(params[:ids]).map(&:to_i).sort
    if params[:shown] != Admin::CandidatesController.fingerprint(shown)
      return redirect_to(admin_inbox_path, alert: "The list changed since you opened it, so nothing was done. Check it and try again.")
    end

    still = ->(candidate) { "Data Quality's check on it changed" unless candidate.dq_recommendation == "approve" && DataQuality::Recommendations.current?(candidate) }
    results = DataQuality::Review.approve(shown, by: actor, reason: "Approved in Today: Data Quality checked it", safe_check: still)
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Done: #{helpers.pluralize(done.size, 'item')} live." if done.any?
    flash[:alert] = "#{helpers.pluralize(stopped.size, 'item')} stayed: #{stopped.flat_map(&:errors).uniq.to_sentence}." if stopped.any?
    redirect_to admin_inbox_path
  end

  # Undo a No: the claim goes back to be decided again.
  def undo
    result = DataQuality::Review.reopen([ params[:candidate_id].to_i ], by: actor, reason: "Undone in Today").sole
    if result&.ok? then flash[:notice] = "Undone. It's back in Today."
    else flash[:alert] = "Can't undo: #{Array(result&.errors).to_sentence}."
    end
    redirect_to admin_inbox_path
  end
end
