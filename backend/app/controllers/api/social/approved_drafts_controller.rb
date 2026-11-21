# A draft the graders (GTM, Founder, Data Quality) approved, handed over without a console step (#896). It creates a DRAFTED
# SocialPost that appears in Admin > Posts with "Send this draft"; nothing is ever sent from here.
#
#   POST /api/social/approved_drafts { platform, slug, text, link, sha256, graders: [...], source_url? }
#     => 201 { id, status: "drafted", text_hash, warnings: [...] } or 422 { errors: [...] }
class Api::Social::ApprovedDraftsController < ActionController::API
  include Api::SocialApproval

  def create
    result = SocialAgent::ApprovedDraft.call(platform: params[:platform].to_s, slug: params[:slug].to_s, text: params[:text].to_s, link: params[:link].to_s,
      sha256: params[:sha256].to_s, graders: Array(params[:graders]).map(&:to_s), source_url: params[:source_url].to_s.presence)
    if result.errors.any?
      render json: { errors: result.errors }, status: :unprocessable_entity
    else
      post = result.post
      render json: { id: post.id, status: post.status, platform: post.platform, text_hash: post.text_hash, link: post.link, warnings: result.warnings }, status: :created
    end
  end
end
