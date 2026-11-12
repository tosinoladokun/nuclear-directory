# Today as Tosin's inbox (#548): Create, Approve or No on what's new, a
# change to something already there, and a week of his decisions; a No has an
# Undo for an hour. Nothing goes live without his Yes; every decision is checked again
# under its locks, as everywhere else.
class Admin::InboxController < Admin::BaseController
  # Rows one "selected" request decides, so it stays well under the web timeout (Infra).
  SELECTED_MAX = 50

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

  # Add a lead (#752): found in the background; it comes back as a Create, or as couldn't confirm.
  def suggest
    if (leads = CompanySuggestion.suggest_lines(params[:suggestion], by: actor))
      flash[:notice] = leads.one? ? "Added. It's being found now." : "Added #{leads.size} leads. They're being found now."
    else
      flash[:alert] = "Type a company name, website or link, one per line " \
        "(#{CompanySuggestion::MAX_LINES} lines and #{CompanySuggestion::MAX} characters a line at most)."
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
    if params[:shown] != OwnerInbox.new.yes_all_fingerprint
      return redirect_to(admin_inbox_path, alert: "The list changed since you opened it, so nothing was done. Check it and try again.")
    end

    results = DataQuality::Recommendations.accept(items, by: actor, first_hand: true)
    # A created company's field claims (#760) go with it, each checked again.
    created = items.map(&:candidate_id) & Candidate.where(id: items.map(&:candidate_id), status: "merged").pluck(:id)
    field_ids = DataQuality::FieldEvidence.fields_of(created).where.not(subject_id: nil).pluck(:id) # each rechecked in approve
    results += DataQuality::Review.approve(field_ids, by: actor, reason: "With its Create") if field_ids.any?
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Done: #{helpers.pluralize(done.size, 'item')} live." if done.any?
    flash[:alert] = "#{helpers.pluralize(stopped.size, 'item')} stayed: #{stopped.flat_map(&:errors).uniq.to_sentence}." if stopped.any?
    redirect_to admin_inbox_path
  end

  # Yes or No on the rows he ticked (#771): each decided exactly as if clicked on its own, one after another,
  # so one that stops doesn't stop the rest. A change's Yes takes the new value, its No keeps his.
  def decide_selected
    yes = params[:decision] == "yes"
    picks = Array(params[:selected]).compact_blank.uniq
    return redirect_to(admin_inbox_path, alert: "Tick at least one row first.") if picks.empty?

    rest = picks.size - SELECTED_MAX
    picks = picks.first(SELECTED_MAX)
    failed = []
    picks.each do |pick|
      errors = decide_pick(pick, yes:)
      failed << (errors.to_sentence.presence || "not done") if errors
    end
    done = picks.size - failed.size
    message = "Done #{done}"
    message += ", #{failed.size} failed: #{failed.uniq.to_sentence}" if failed.any?
    message += ". #{rest} not done yet: select again for the rest" if rest.positive?
    flash[failed.any? ? :alert : :notice] = "#{message}."
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
    # "claim:<id>,<id>…" (a row and its copies) or "record:<Type>:<id>". Returns the errors, or nil when done.
    def decide_pick(pick, yes:)
      kind, rest = pick.split(":", 2)
      result = case kind
      when "claim"
        ids = rest.to_s.split(",").map(&:to_i).select(&:positive?)
        return [ "unknown row" ] if ids.empty?
        # Gone since the page loaded (decide and approve skip ids they can't find): not a success.
        return [ "no longer in the inbox" ] if Candidate.where(id: ids).count < ids.uniq.size

        results = yes ? DataQuality::Review.approve(ids, by: actor, reason: "Approved in Today") : DataQuality::Review.reject(ids, by: actor, reason: "Said no in Today")
        stopped = results.reject(&:ok?)
        return stopped.flat_map(&:errors).uniq if stopped.any?

        keep_as_lead(ids.first) unless yes
        return nil
      when "record"
        type, id = rest.to_s.split(":", 2)
        return [ "unknown row" ] unless %w[Organization Facility].include?(type)

        yes ? DataQuality::Review.approve_fact(type:, id: id.to_i, by: actor, reason: "Created in Today") : DataQuality::Review.reject_fact(type:, id: id.to_i, by: actor, reason: "Said no in Today")
      else return [ "unknown row" ]
      end
      result.ok? ? nil : Array(result.errors)
    rescue StandardError => e
      [ e.message ]
    end

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
