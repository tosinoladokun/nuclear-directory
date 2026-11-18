# Weekday mornings (config/recurring.yml): one post per platform from the social agent (#769), if switched on.
class SocialPostJob < ApplicationJob
  queue_as :default

  # Each platform on its own: one failing (the model unreachable) never skips the other (Infra).
  def perform
    SocialChannel::PLATFORMS.each do |platform|
      SocialAgent.run(platform)
    rescue StandardError => error
      Rails.error.report(error, context: { social_platform: platform })
    end
  end
end
