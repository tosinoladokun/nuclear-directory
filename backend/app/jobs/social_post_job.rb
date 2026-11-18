# Weekday mornings (config/recurring.yml): one post per platform from the social agent (#769), if switched on.
class SocialPostJob < ApplicationJob
  queue_as :default

  def perform = SocialChannel::PLATFORMS.each { |platform| SocialAgent.run(platform) }
end
