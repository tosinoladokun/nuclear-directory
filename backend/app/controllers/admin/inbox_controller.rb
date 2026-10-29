# Today as Tosin's inbox (#548): Create, Approve or No on what's new, a
# change to something already there, and a week of his decisions; a No has an
# Undo for an hour. Nothing goes live without his Yes; every decision is checked again
# under its locks, as everywhere else.
class Admin::InboxController < Admin::BaseController
  def show
    @inbox = OwnerInbox.new
  end

  # Yes or No on one fact, with its copies from other pages. A No gets an
  # Undo for an hour (Today review's: every copy back as it was, or none).
  def decide
    ids = Array(params[:ids]).map(&:to_i).presence || [ params[:candidate_id].to_i ]
    yes = params[:decision] == "yes"
    before = ids.map { |id| DataQuality::Review.undo_state(id) } unless yes
    results = if yes
      DataQuality::Review.approve(ids, by: actor, reason: "Approved in Today")
    else
      DataQuality::Review.reject(ids, by: actor, reason: "Said no in Today")
    end
    stopped = results.reject(&:ok?)
    if stopped.empty?
      kept = keep_as_lead(ids.first) unless yes
      flash[:notice] = if yes then "Done. It's live."
      elsif kept then "Said no. It's kept in Leads."
      elsif params[:kind] == "change" then "Kept what you decided."
      else "Said no."
      end
      undoable = Array(before).map { |state| DataQuality::Review.undoable(state, by: actor) }
      flash[:undo] = undo_verifier.generate(undoable, expires_in: 1.hour) if !yes && undoable.all? && undoable.size <= 20
    else
      flash[:alert] = "Not done: #{stopped.flat_map(&:errors).uniq.to_sentence}."
    end
    redirect_to admin_inbox_path
  end

  # Create or No on a pending company or plant that has no open claim.
  def decide_record
    type, id = params[:type], params[:id].to_i
    result = if params[:decision] == "yes"
      DataQuality::Review.approve_fact(type:, id:, by: actor, reason: "Created in Today")
    else
      DataQuality::Review.reject_fact(type:, id:, by: actor, reason: "Said no in Today")
    end
    if result.ok? then flash[:notice] = params[:decision] == "yes" ? "Done. It's live." : "Said no."
    else flash[:alert] = "Not done: #{Array(result.errors).to_sentence}."
    end
    redirect_to admin_inbox_path
  end

  # Yes to every item Data Quality checked that the page showed: the same
  # calls on the same claims (fingerprint), each accepted through Data
  # Quality's Accept, which checks it all again under the decision's locks.
  def yes_all
    items = OwnerInbox.new.checked_items
    if params[:shown] != DataQuality::Recommendations.fingerprint(items)
      return redirect_to(admin_inbox_path, alert: "The list changed since you opened it, so nothing was done. Check it and try again.")
    end

    results = DataQuality::Recommendations.accept(items, by: actor, first_hand: true)
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Done: #{helpers.pluralize(done.size, 'item')} live." if done.any?
    flash[:alert] = "#{helpers.pluralize(stopped.size, 'item')} stayed: #{stopped.flat_map(&:errors).uniq.to_sentence}." if stopped.any?
    redirect_to admin_inbox_path
  end

  # Undo the last No, while nothing has changed it since.
  def undo
    state = undo_verifier.verified(params[:token].to_s)
    result = state && DataQuality::Review.undo_all(Array.wrap(state), by: actor)
    if result&.ok? then flash[:notice] = "Undone. It's back in Today."
    else flash[:alert] = "Can't undo this: #{Array(result&.errors).to_sentence.presence || 'the Undo has expired'}."
    end
    redirect_to admin_inbox_path
  end

  private
    # A No on a new company or plant is never final (PM, 25 Oct): its name
    # goes to Leads, which are never thrown away.
    def keep_as_lead(candidate_id)
      claim = Candidate.includes(:source).find_by(id: candidate_id)
      return unless claim&.proposed_subject && %w[organization facility].include?(claim.kind)

      Lead.sighted!(name: claim.payload.to_h["name"], kind: claim.kind == "facility" ? "plant" : "company",
        key: "today_no:#{claim.id}", label: "Said no in Today", url: claim.source&.url)
    end

    # Its own key: a token works only on the page that made it.
    def undo_verifier = Rails.application.message_verifier(:owner_inbox_undo)
end
