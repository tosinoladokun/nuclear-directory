# Every five minutes (config/recurring.yml): the social agent's switch is honoured for posts already queued in the
# publisher, and due posts are read back (#769). No call at all while nothing is queued.
class SocialSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "social_agent", duration: 1.hour if respond_to?(:limits_concurrency)

  def perform
    SocialAgent.sync if SocialPost.where(status: "queued").exists?
  end
end
