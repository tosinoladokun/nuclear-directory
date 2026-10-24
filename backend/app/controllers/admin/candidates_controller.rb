# Deciding on claims the pipeline found: approve, edit then approve,
# reject, approve all. They're listed on Checks (#201), where every action
# goes back to.
class Admin::CandidatesController < Admin::BaseController
  # The old queue's address leads to Checks.
  def index
    redirect_to admin_checks_path
  end

  # One claim (candidate_id), or the selected ones (candidate_ids[]): bulk
  # approval covers recommended claims only.
  def approve
    single = params[:candidate_id].present?
    ids = single ? [ params[:candidate_id] ] : Array(params[:candidate_ids])
    if ids.empty?
      flash[:alert] = "Select at least one claim to approve."
      return redirect_after queue_path
    end

    results = DataQuality::Review.approve(ids.map(&:to_i), by: actor, only_recommended: !single)
    flash_decision(results, "Approved")
    # From an item page, on to the next item once it's approved; from the list, or if refused, back to the list.
    redirect_after after_decision(results, queue_path)
  end

  # Every recommended claim the Checks filter shows (its chip and source), in
  # the background (DataQuality::ApproveAllJob); or, with reason or run_id,
  # those that match them. Only recommended claims: claims that need review
  # each get a look on their own.
  def approve_all
    ids =
      if params[:reason].present? || params[:run_id].present?
        DataQuality::Review.candidate_ids(queue: :recommended, reason: params[:reason].presence, run_id: params[:run_id].presence&.to_i)
      else
        DataQuality::Review.safe_ids(category: params[:category].presence_in(Admin::ChecksController::CATEGORIES) || "all",
          source_kind: params[:source].presence)
      end
    if ids.empty?
      flash[:alert] = "Nothing to approve: no recommended claims match these filters."
    elsif params[:shown] != self.class.fingerprint(ids)
      # Only what the person saw and confirmed: if claims were recommended,
      # decided or dropped since the page loaded, nothing is approved.
      flash[:alert] = "The queue changed since you opened it, so nothing was approved. Check the count and try again."
    else
      DataQuality::ApproveAllJob.perform_later(ids, by: actor)
      flash[:notice] = "Approving #{helpers.pluralize(ids.size, 'recommended claim')}. Refresh in a minute to see Checks " \
        "clear. Any claim that's changed since it was recommended stays here."
    end
    redirect_after queue_path
  end

  # Which claims "Approve all" covered when the page was shown, compared on
  # the click so exactly those are approved.
  def self.fingerprint(ids) = Digest::SHA256.hexdigest(ids.join(","))

  def reject
    id = params.require(:candidate_id).to_i
    results = DataQuality::Review.reject([ id ], by: actor, reason: params.dig(:reasons, id.to_s).presence)
    flash_decision(results, params[:kept].present? ? "Kept" : "Rejected")
    redirect_after after_decision(results, queue_path)
  end

  # Close: the claim restates what the site already shows. Records the
  # decision; nothing live changes.
  def close
    id = params.require(:candidate_id).to_i
    results = DataQuality::Review.confirm_identical([ id ], by: actor)
    results = [ DataQuality::Review::Result.new(candidate_id: id, ref: nil, errors: [ "it's already decided" ]) ] if results.empty?
    flash_decision(results, "Closed")
    redirect_after after_decision(results, queue_path)
  end

  def edit
    @item = DataQuality::Review.candidate(params[:id].to_i) or raise ActiveRecord::RecordNotFound
    @fields = editable_fields(@item)
    @read_only = read_only_fields(@item)
    @list = list_position(@item.candidate_id) unless from_fact
  end

  def update
    item = DataQuality::Review.candidate(params[:id].to_i) or raise ActiveRecord::RecordNotFound
    # Only single values come from the form; lists (aliases) and nested ends are read-only.
    # A read-only field the form doesn't show is still passed on, so Review
    # drops it unchanged and refuses it changed (an older page, say).
    scalars = editable_fields(item).reject { |name| item.payload[name].is_a?(Array) || item.payload[name].is_a?(Hash) }
    values = params.fetch(:values, {}).permit(*scalars).to_h.transform_values(&:presence)
    result = DataQuality::Review.edit_and_approve(item.candidate_id, attributes: values, by: actor,
      reason: params[:note].presence)
    if result.ok?
      flash_results([ result ], "Approved")
      # Opened from a fact page: on to where it said (done), else back to it,
      # which moves on through Live.
      return redirect_after(done_path || from_fact) if from_fact

      # On to the next claim in the list it was opened from; back to the list after the last.
      following = list_ids.find { |id| id > item.candidate_id }
      redirect_after(following ? edit_admin_candidate_path(following, **item_context) : queue_path)
    else
      @item = item
      @fields = editable_fields(item)
      @read_only = read_only_fields(item)
      @list = list_position(item.candidate_id) unless from_fact
      @errors = result.errors
      render :edit, status: :unprocessable_content
    end
  end

  private
    # Checks' filter chip and source, carried through edit and back.
    # reason and run_id narrow Approve all, as before.
    def filters = params.permit(:category, :source, :reason, :run_id).to_h.compact_blank
    helper_method :filters

    # The list a decision returns to: the one it was opened from (back), else
    # Checks with the chip and source, at the row after the one decided on
    # (anchor), so the place on the page isn't lost.
    def queue_path = with_anchor(back_path(admin_checks_path(filters.slice("category", "source"))))

    # The edit page's list: the claims of the Checks filter it was opened
    # from, oldest first, for Previous and Next and moving on after approving.
    def list_ids
      category = (filters["category"] || list_filters["category"]).presence_in(Admin::ChecksController::CATEGORIES) || "all"
      DataQuality::Review.check_ids(category:, source_kind: (filters["source"] || list_filters["source"]).presence)
    end

    def item_context = { back: params[:back].presence, next: from_fact, done: done_path, **filters.slice("category", "source").symbolize_keys }.compact
    helper_method :item_context

    # The fact page this edit was opened from in Live (next), if any. Its
    # Previous and Next are Live's, so this page has none of Checks'.
    def from_fact = next_or(nil)
    helper_method :from_fact

    # Where approving or rejecting from the edit page goes when it was opened
    # through a Record row's claims: the next claim, or the row after the last.
    def done_path
      done = params[:done].to_s
      done if done.match?(%r{\A/admin(?:[/?#]|\z)})
    end
    helper_method :done_path

    def list_position(id)
      ids = list_ids
      index = ids.index(id) or return
      path = ->(other) { other && edit_admin_candidate_path(other, **item_context) }
      { index: index + 1, total: ids.size, previous: path.(index.positive? ? ids[index - 1] : nil), next: path.(ids[index + 1]) }
    end

    # The claim's own values the form shows; link ends were matched and aren't shown.
    def editable_fields(item)
      item.payload.keys - DataQuality::Review::NOT_EDITABLE
    end

    # Shown, but not editable: what identifies the claim (a role's role, a
    # technology claim's technology). Approving refuses a change to them.
    def read_only_fields(item) = item.payload.keys & DataQuality::Review.read_only_keys(item.kind)
end
