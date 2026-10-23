# Today (#373): the admin's daily plan, four steps, then done. Steps 1 and 2
# are marked here; step 3 is Checks (the list and Aminah's Accept), and step
# 4 is the correction requests. Nothing here decides a fact.
class Admin::TodayController < Admin::BaseController
  # Undo is offered for a group of at most this many copies (a small signed token).
  UNDO_LIMIT = 5
  UNDO_BYTES = 1_500

  def show
    load_today
  end

  # Step 1 ("Looks fine, next") or step 2 ("No list from Aminah today").
  def done
    Today.new.mark_done!(params[:step], by: actor, note: params[:note].presence_in(TodayStep::NOTES))
    redirect_after admin_today_path
  end

  def undo
    Today.new.undo!(params[:step])
    redirect_after admin_today_path
  end

  # Step 2: Aminah's list, recorded as Data Quality's recommendations (#355).
  # It decides nothing. Read in full, the step is done; lines it couldn't
  # add are listed, with the list kept in the box to fix.
  def list
    recorded = DataQuality::Recommendations.record(params[:list].to_s, by: actor)
    if recorded.recorded.zero? && recorded.errors.empty?
      flash[:alert] = "Paste #{t('admin.reviewers.reviewer')}'s list first, or choose “No list from #{t('admin.reviewers.reviewer')} today”."
      return redirect_after admin_today_path
    end
    if recorded.errors.empty?
      Today.new.mark_done!("list", by: actor)
      flash[:notice] = "Added #{helpers.pluralize(recorded.recorded, 'fact')} from #{t('admin.reviewers.reviewer')}."
      return redirect_after admin_today_path
    end

    @recorded, @errors, @list = recorded.recorded, recorded.errors, params[:list].to_s
    load_today
    render :show, status: :unprocessable_content
  end

  # Step 3: the facts waiting, each with Joy's and Aminah's verdicts.
  def review
    @review = TodayReview.new(shown: shown_counts)
    @pending = DataQuality::Review.pending_count
    @restating = DataQuality::Review.restating_ids(TodayReview::GROUPS.flat_map { |group| @review.rows(group).flat_map(&:candidate_ids) }, by: actor)
  end

  # Accept or Reject one fact, as the admin's decision (every check still runs).
  # The same fact from other pages is decided with it (each checked as usual).
  def decide
    id = params[:candidate_id].to_i
    ids = [ id, *(Array(params[:same]).map(&:to_i) - [ id ]) ]
    before = ids.map { |each_id| DataQuality::Review.undo_state(each_id) } if params[:decision] == "reject"
    results = case params[:decision]
    when "accept" then DataQuality::Review.approve(ids, by: actor, reason: "Accepted in Today")
    when "close" then DataQuality::Review.confirm_identical(ids, by: actor)
    else DataQuality::Review.reject(ids, by: actor) # its notes kept, so Undo loses nothing
    end
    stopped = ids.filter_map { |each_id| results.find { |r| r.candidate_id == each_id } || DataQuality::Review::Result.new(candidate_id: each_id, ref: nil, errors: [ "it was decided already" ]) }.reject(&:ok?)

    if stopped.empty?
      flash[:notice] = { "accept" => "Accepted.", "close" => "Closed. Nothing on the site changed." }.fetch(params[:decision], "Rejected.")
      # Undo only for a Reject, of every copy at once, while it's as left.
      undoable = (before || []).map { |state| DataQuality::Review.undoable(state, by: actor) }
      token = undo_verifier.generate(undoable, expires_in: 1.hour) if params[:decision] == "reject" && undoable.all? && undoable.size <= UNDO_LIMIT
      # The session cookie holds 4 KB in all; a token over budget gets no Undo.
      if token && token.bytesize <= UNDO_BYTES
        flash[:undo] = token
      elsif params[:decision] == "accept"
        flash[:notice] += " To take it back, change it on its record."
      end
    else
      verb = { "accept" => "publish", "close" => "close" }.fetch(params[:decision], "reject")
      flash[:alert] = "Can't #{verb} #{stopped.size == ids.size ? 'this' : "#{stopped.size} of #{ids.size}"} yet: " +
        stopped.map { |r| "#{"##{r.candidate_id}: " if ids.size > 1}#{Array(r.errors).to_sentence.presence || 'it was decided already'}" }.join("; ")
    end
    redirect_after admin_today_review_path(shown: shown_counts.presence)
  end

  # Undo the last Accept or Reject, while nothing else has changed it.
  def undo_decision
    state = undo_verifier.verified(params[:token].to_s)
    result = state && DataQuality::Review.undo_all(Array.wrap(state), by: actor)
    if result&.ok?
      flash[:notice] = "Undone. It's waiting again."
    else
      flash[:alert] = "Can't undo this: #{Array(result&.errors).to_sentence.presence || 'the Undo has expired'}."
    end
    redirect_after admin_today_review_path(shown: shown_counts.presence)
  end

  # The shortcut: exactly the agreed facts the page showed (its fingerprint),
  # each accepted as Aminah's list's Accept does: her call, reason and the
  # fact checked again under the decision's locks.
  def agreed
    # One snapshot: the same items are fingerprinted and accepted.
    review = TodayReview.new(shown: shown_counts)
    items = review.agreed_items
    copies = review.agreed_copies
    if params[:shown_set] != DataQuality::Recommendations.fingerprint(items)
      flash[:alert] = "The list changed since you opened it, so nothing was accepted. Check it and try again."
      return redirect_after(admin_today_review_path(shown: shown_counts.presence))
    end

    # One copy of each fact through Aminah's Accept (her call rechecked under
    # its locks); once that's in, the fact's other copies are approved with it
    # (their own sources and quotes), not held back by the decision just made.
    firsts = items.select { |item| copies.key?(item.candidate_id) }
    # Each other copy rechecked under its decision lock against what the page
    # showed: Aminah's call, reason and snapshot, and Joy's recommendation.
    # Aminah's review must still describe the claim as it is now (a merge
    # repoints claims without touching her fields), and the record must be
    # as the first copy's acceptance left it: a person's edit in between is
    # never overwritten. Only this group's own decision is let through.
    directory = DataQuality::DirectoryClient.new
    shown = items.index_by(&:candidate_id)
    record_state = ->(type, id) { [ directory.verification_history(type:, id:).size, directory.fact(type:, id:)&.values ] }
    after_first = {}
    unchanged = lambda do |candidate|
      item = shown.fetch(candidate.id)
      same = [ candidate.dq_recommendation, candidate.dq_reason, candidate.dq_payload_sha256 ] == [ item.call, item.reason, item.snapshot ]
      next "Aminah's or Joy's call on it changed after the page loaded" unless same && DataQuality::Recommendations.current?(candidate) &&
        candidate.ai_recommendation == "recommend_publish" && !candidate.status_needs_review?
      next unless candidate.subject_id

      directory.lock_fact(type: candidate.subject_type, id: candidate.subject_id)
      expected = after_first[[ candidate.subject_type, candidate.subject_id ]]
      "its record changed after the first page's copy was accepted" if expected && record_state.(candidate.subject_type, candidate.subject_id) != expected
    end
    # Each fact's copies are decided in one transaction holding its record's
    # lock from before the first write, so no one else's edit lands between
    # the first copy and the baseline the others are checked against.
    results = firsts.flat_map do |item|
      claim = Candidate.find(item.candidate_id)
      key = [ claim.subject_type, claim.subject_id ]
      ActiveRecord::Base.transaction(requires_new: true) do
        directory.lock_fact(type: claim.subject_type, id: claim.subject_id) if claim.subject_id
        first = DataQuality::Recommendations.accept([ item ], by: actor)
        rest = first.sole.ok? ? copies.fetch(item.candidate_id, []) : []
        claim.reload
        key = [ claim.subject_type, claim.subject_id ]
        after_first[key] = record_state.(*key) if claim.subject_id && rest.any?
        first + rest.flat_map do |id|
          DataQuality::Review.approve([ id ], by: actor, reason: "Accepted in Today: another page of the same fact", safe_check: unchanged).tap do |result|
            # This group's own write is the new baseline for the next copy.
            after_first[key] = record_state.(*key) if result.sole.ok? && claim.subject_id
          end
        end
      end
    end
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Accepted #{helpers.pluralize(done.size, 'fact')}." if done.any?
    if stopped.any?
      flash[:alert] = "#{helpers.pluralize(stopped.size, 'fact')} can't be published yet, so #{stopped.one? ? 'it stays' : 'they stay'} below: " +
        stopped.map { |result| "##{result.candidate_id}: #{Array(result.errors).to_sentence.presence || 'it was decided already'}" }.join("; ")
    end
    redirect_after admin_today_review_path(shown: shown_counts.presence)
  end

  private
    def undo_verifier = Rails.application.message_verifier(:today_undo)

    # How many pages of each run are shown: ?shown[agree]=2.
    def shown_counts
      shown = params[:shown]
      shown.respond_to?(:permit) ? shown.permit(*TodayReview::GROUPS).to_h.transform_values(&:to_i).select { |_, pages| pages > 1 } : {}
    end

    def load_today
      @today = Today.new
      @sources = DataQuality::Status.by_kind(within: @today.crawl_window).index_by(&:source_kind)
      @decisions = @today.decisions(by: actor) if @today.done?
    end
end
