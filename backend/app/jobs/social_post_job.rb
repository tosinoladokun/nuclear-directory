# Weekday mornings (config/recurring.yml): one post per platform from the social agent (#769), if switched on.
class SocialPostJob < ApplicationJob
  queue_as :default
  # One at a time with the sync, so two runs can never pick the same item or post twice (Copilot).
  limits_concurrency to: 1, key: "social_agent", duration: 1.hour if respond_to?(:limits_concurrency)

  # Each platform on its own: one failing (the model unreachable) never skips the other (Infra).
  # drafts_only: Admin > Posts' Draft now (PM, 20 Nov): today's draft, never sent.
  def perform(drafts_only: false)
    # The graders' approved rows go out FIRST on every platform, before any model call: a slow generation on one platform never delays the other's
    # dispatch (GTM). Handed to Buffer at about 8:30; it publishes DELAY (15 minutes) later.
    unless drafts_only
      SocialChannel::PLATFORMS.each do |platform|
        SocialAgent.send_scheduled(platform)
      rescue StandardError => error
        Rails.error.report(error, context: { social_platform: platform, step: "approved queue" })
      end
    end
    SocialChannel::PLATFORMS.each do |platform|
      # The server only DRAFTS what the agent writes (never sends it): what goes out is the graders' approved queue (PM, #897).
      SocialAgent.run(platform, drafts_only: true)
    rescue StandardError => error
      Rails.error.report(error, context: { social_platform: platform })
    end
  end
end
