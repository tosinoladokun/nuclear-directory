# Today (#373): the admin's daily plan, four steps, then done. Steps 1 and 2
# are marked here; step 3 is Checks (the list and Aminah's Accept), and step
# 4 is the correction requests. Nothing here decides a fact.
class Admin::TodayController < Admin::BaseController
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
    @review = TodayReview.new
  end

  # Accept or Reject one fact, as the admin's decision (every check still runs).
  def decide
    id = params[:candidate_id].to_i
    result = if params[:decision] == "accept"
      DataQuality::Review.approve([ id ], by: actor, reason: "Accepted in Today").first
    else
      DataQuality::Review.reject([ id ], by: actor, reason: "Rejected in Today").first
    end
    if result&.ok?
      flash[:notice] = params[:decision] == "accept" ? "Accepted. It's live." : "Rejected."
    else
      flash[:alert] = "Can't #{params[:decision] == 'accept' ? 'publish' : 'reject'} this yet: #{Array(result&.errors).to_sentence.presence || 'it was decided already'}"
    end
    redirect_after admin_today_review_path
  end

  # The shortcut: every fact Joy and Aminah both say to accept, each checked again.
  def agreed
    ids = TodayReview.new.rows("agree").map(&:candidate_id)
    # Aminah reviewed each, so the first-batch hold she exists for is lifted, as Data Quality's Accept does.
    results = DataQuality::Review.approve(ids, by: actor, reason: "Accepted in Today: Joy and Aminah agree", only_recommended: true,
      data_quality_reviewed: true)
    done, stopped = results.partition(&:ok?)
    flash[:notice] = "Accepted #{helpers.pluralize(done.size, 'fact')}." if done.any?
    flash[:alert] = "#{helpers.pluralize(stopped.size, 'fact')} can't be published yet; #{stopped.one? ? 'it stays' : 'they stay'} below with why." if stopped.any?
    redirect_after admin_today_review_path
  end

  private
    def load_today
      @today = Today.new
      @sources = DataQuality::Status.by_kind.index_by(&:source_kind)
      @decisions = @today.decisions(by: actor) if @today.done?
    end
end
