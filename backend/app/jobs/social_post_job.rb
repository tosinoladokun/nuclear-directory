# Weekday mornings (config/recurring.yml): one post per platform from the social agent (#769), if switched on.
class SocialPostJob < ApplicationJob
  queue_as :default
  # One at a time with the sync, so two runs can never pick the same item or post twice (Copilot).
  limits_concurrency to: 1, key: "social_agent", duration: 1.hour if respond_to?(:limits_concurrency)

  # Each platform on its own: one failing (the model unreachable) never skips the other (Infra).
  # drafts_only: Admin > Posts' Draft now (PM, 20 Nov): today's draft, never sent.
  def perform(drafts_only: false)
    SocialChannel::PLATFORMS.each do |platform|
      SocialAgent.send_scheduled(platform) unless drafts_only
      SocialAgent.run(platform, drafts_only:)
    rescue StandardError => error
      Rails.error.report(error, context: { social_platform: platform })
    end
  end
end
