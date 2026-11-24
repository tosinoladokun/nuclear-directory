# A draft the graders (GTM, Founder, Data Quality) approved, handed over without a console step (#896). It creates a DRAFTED
# SocialPost that appears in Admin > Posts with "Send this draft"; nothing is ever sent from here.
#
#   POST /api/social/approved_drafts { platform, slug, text, link, sha256, graders: [...], source_url?, send_on? }
#     => 201 { id, status: "drafted", text_hash, send_on, warnings: [...] } or 422 { errors: [...], codes: [...] }
#   Data Quality's PASS of the exact sha256 must be on file first (POST /api/dq/social_approvals). send_on (a weekday, today or later): the
#   8:30 job sends it that morning even when the platform is on Drafts only (Off stops it).
class Api::Social::ApprovedDraftsController < ActionController::API
  include Api::SocialApproval

  def create
    result = SocialAgent::ApprovedDraft.call(platform: params[:platform].to_s, slug: params[:slug].to_s, text: params[:text].to_s, link: params[:link].to_s,
      sha256: params[:sha256].to_s, graders: Array(params[:graders]).map(&:to_s), source_url: params[:source_url].to_s.presence, send_on: params[:send_on].to_s.presence,
      annotations: native_annotations, card: native_card, content_payload_sha256: params[:content_payload_sha256].to_s.presence, opener_pattern_id: params[:opener_pattern_id].to_s.presence)
    if result.errors.any?
      render json: { errors: result.errors, codes: result.codes }, status: :unprocessable_entity
    else
      post = result.post
      render json: { id: post.id, status: post.status, platform: post.platform, text_hash: post.text_hash, link: post.link, send_on: post.send_on, exact_text: post.exact_text,
                     warnings: result.warnings }, status: :created
    end
  end

  # What waits and what went out, for the loader's readback (GTM): the queue by day with its hashes, then the last ten sent.
  #   GET /api/social/approved_drafts => { queue: [{ id, send_on, platform, company, status, text_sha256, approved_sha256, content_payload_sha256, opener_pattern_id,
  #     exact_text, warnings }], sent: [{ id, platform, company, status, sent_on, permalink }] }
  def index
    row = ->(post) { { id: post.id, send_on: post.send_on, platform: post.platform, company: post.subject.try(:slug), status: post.status, text_sha256: Digest::SHA256.hexdigest(post.text.to_s),
                       approved_sha256: post.approved_sha256, content_payload_sha256: post.content_payload_sha256, opener_pattern_id: post.opener_pattern_id, exact_text: post.exact_text,
                       warnings: post.warnings.to_s.split("\n") } }
    sent = SocialPost.where.not(approved_sha256: nil).where(status: SocialPost::SENT).order(Arel.sql("COALESCE(sent_on, created_at::date) DESC"), id: :desc).limit(10).includes(:subject).map do |post|
      { id: post.id, platform: post.platform, company: post.subject.try(:slug), status: post.status, sent_on: post.sent_on, permalink: post.permalink }
    end
    render json: { queue: SocialPost.waiting.includes(:subject).order(:send_on, :platform).map(&row), sent: }
  end

  private
    def native_annotations
      Array(params[:annotations]).filter_map { |annotation| annotation.permit(:id, :entity, :start, :length, :link, :localizedName, :vanityName).to_h if annotation.respond_to?(:permit) }
    end

    def native_card = params[:card].respond_to?(:permit) ? params[:card].permit(:title, :description, :image_url).to_h : nil
end
