# Data Quality records its PASS of an exact text's hash (#897), after grading it; the approved-drafts endpoint requires it.
#
#   POST /api/dq/social_approvals { platform, slug, sha256, note? } => 201 { id, platform, slug, sha256 } (the same hash again: 200)
#   Any change to the text changes the hash, so an edited text needs a new approval.
class Api::Dq::SocialApprovalsController < ActionController::API
  include Api::DqAgent

  def create
    approval = SocialApproval.find_or_initialize_by(platform: params[:platform].to_s, slug: params[:slug].to_s, sha256: params[:sha256].to_s.strip.downcase)
    status = approval.new_record? ? :created : :ok
    approval.approved_by = "agent:data-quality"
    approval.note = params[:note].to_s.presence
    if approval.save
      render json: { id: approval.id, platform: approval.platform, slug: approval.slug, sha256: approval.sha256 }, status:
    else
      render json: { errors: approval.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
