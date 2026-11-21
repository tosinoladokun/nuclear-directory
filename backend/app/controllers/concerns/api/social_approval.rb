# GTM's route for graders-approved spotlight drafts (#896): "Authorization: Bearer <token>", whose SHA-256 must equal
# SOCIAL_APPROVE_TOKEN_DIGEST. Without that variable the endpoint doesn't exist (404). Bearer only, constant-time compare,
# rate-limited before auth (as Api::DqAgent).
module Api::SocialApproval
  extend ActiveSupport::Concern
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  included do
    rate_limit to: 30, within: 1.minute, store: RATE_LIMIT_STORE, by: -> { "social-approval" },
      with: -> { head :too_many_requests, "Retry-After" => "60" }
    before_action :require_approver
  end

  private
    def require_approver
      digest = ENV["SOCIAL_APPROVE_TOKEN_DIGEST"].to_s.strip.downcase
      return head(:not_found) unless digest.match?(/\A\h{64}\z/)

      presented = request.authorization.to_s[/\ABearer (\S+)\z/, 1].to_s
      ok = ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(presented), digest)
      render(json: { error: "unauthorized" }, status: :unauthorized) unless ok && presented.present?
    end
end
