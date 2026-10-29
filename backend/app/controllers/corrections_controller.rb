# "Report a correction" (#44): a short anonymous form, prefilled with the
# fact or page it's about. A hidden honeypot field catches bots, and a
# rate limit keyed on a salted hash of the visitor's IP (kept only in the
# cache, never in the database) stops floods.
class CorrectionsController < ApplicationController
  RATE_LIMIT = 5
  # The app's cache in production; tests use their own store, since the
  # test cache keeps nothing.
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  rate_limit to: RATE_LIMIT, within: 10.minutes, only: :create, store: RATE_LIMIT_STORE,
    by: -> { Digest::SHA256.hexdigest("#{request.remote_ip}:#{Date.current}:#{Rails.application.secret_key_base}") },
    with: -> { too_many }

  def new
    @report = CorrectionReport.new(subject: subject, page_path: safe_path(params[:page]))
  end

  def create
    # A filled honeypot looks like success, so bots learn nothing.
    return redirect_to(correction_sent_path(page: safe_path(params[:page_path]))) if params[:website].present?

    @report = CorrectionReport.new(report_params)
    if @report.save
      ListingSubmission.call(@report)
      # Its path only: a query string or fragment can hold anything (the report keeps it).
      path = @report.page_path.split(/[?#]/).first
      record_type, record_id = record_on(path)
      track_correction_submitted(subject_type: page_kind(path), page_path: path, record_type:, record_id:)
      CorrectionMailer.notify(@report)
      redirect_to correction_sent_path(page: @report.page_path)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def sent
    @page_path = safe_path(params[:page])
  end

  private
    def report_params
      params.permit(:message, :contact, :kind, :source_url, :claimant_name, :claimant_role, :claimant_email, :record_type, :record_id,
        proposed_changes: %i[field value quote]).merge(subject:, page_path: safe_path(params[:page_path]), kind: params[:kind].presence || "correction")
    end

    # What the correction is about: the fact or page it came from.
    def subject = params[:subject].to_s.squish.first(300).presence || "Nuclear Directory"

    # Only a path on this site, so the form never links elsewhere. Browsers
    # read a leading "//" or "/\" as another host, so neither may start it,
    # and no backslash or whitespace is allowed anywhere.
    def safe_path(path) = CorrectionReport.local_path?(path) ? path.to_s : "/"

    # What kind of page a correction is about, for analytics: never which one.
    def page_kind(path)
      case path.to_s
      when %r{\A/companies/} then "company"
      when %r{\A/plants/} then "plant"
      else "other"
      end
    end

    # The company or plant a page shows, as [type, id], for analytics.
    def record_on(path)
      slug = path.to_s[%r{\A/(?:companies|plants)/([\w-]+)\z}, 1] or return
      model = path.start_with?("/companies/") ? Organization : Facility
      id = model.find_by(slug:)&.id
      [ model.name, id ] if id
    end

    def too_many
      @report = CorrectionReport.new(report_params)
      @too_many = true
      render :new, status: :too_many_requests
    end
end
