# Data Quality's agent (#548): "Authorization: Bearer <token>", whose SHA-256
# must equal DQ_AGENT_TOKEN_DIGEST. Without that variable the endpoints don't
# exist (404). Bearer only: no session or cookie is ever read, and the
# presented token is always compared in constant time. Rate-limited before
# auth, so guessing a token is never free (Infra).
module Api::DqAgent
  extend ActiveSupport::Concern
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  included do
    rate_limit to: 60, within: 1.minute, store: RATE_LIMIT_STORE, by: -> { "dq-agent" },
      with: -> { head :too_many_requests, "Retry-After" => "60" }
    before_action :require_agent
  end

  private
    def require_agent
      digest = ENV["DQ_AGENT_TOKEN_DIGEST"].to_s.strip.downcase
      return head(:not_found) unless digest.match?(/\A\h{64}\z/)

      presented = request.authorization.to_s[/\ABearer (\S+)\z/, 1].to_s
      ok = ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(presented), digest)
      render(json: { error: "unauthorized" }, status: :unauthorized) unless ok && presented.present?
    end
end
