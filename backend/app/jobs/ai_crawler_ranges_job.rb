# Refreshes the AI answer crawlers' published IP ranges once a day (#864).
class AiCrawlerRangesJob < ApplicationJob
  queue_as :default

  def perform = AiCrawlerRanges.refresh!
end
