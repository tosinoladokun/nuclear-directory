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
      sha256: params[:sha256].to_s, graders: Array(params[:graders]).map(&:to_s), source_url: params[:source_url].to_s.presence, send_on: params[:send_on].to_s.presence)
    if result.errors.any?
      render json: { errors: result.errors, codes: result.codes }, status: :unprocessable_entity
    else
      post = result.post
      render json: { id: post.id, status: post.status, platform: post.platform, text_hash: post.text_hash, link: post.link, send_on: post.send_on, warnings: result.warnings }, status: :created
    end
  end
end
