require "test_helper"

class AiCrawlerRangesTest < ActiveSupport::TestCase
  setup { AiCrawlerRanges.store.delete(AiCrawlerRanges::CACHE_KEY); AiCrawlerRanges.local = nil }
  teardown { AiCrawlerRanges.store.delete(AiCrawlerRanges::CACHE_KEY); AiCrawlerRanges.local = nil }

  test "refresh keeps each list's prefixes; a failed list keeps its last good ranges; verified checks agent and IP" do
    lists = { "https://openai.com/gptbot.json" => { prefixes: [ { ipv4Prefix: "20.171.206.0/24" } ] }.to_json,
      "https://claude.com/crawling/bots.json" => { prefixes: [ { ipv4Prefix: "216.73.216.0/22" }, { ipv6Prefix: "2600:1f28::/32" } ] }.to_json }
    AiCrawlerRanges.refresh!(get: ->(url) { lists[url] })
    assert AiCrawlerRanges.verified?("20.171.206.10", "GPTBot/1.4")
    assert AiCrawlerRanges.verified?("2600:1f28::5", "ClaudeBot/1.0")
    refute AiCrawlerRanges.verified?("20.171.206.10", "ClaudeBot/1.0"), "another operator's range"
    refute AiCrawlerRanges.verified?("8.8.8.8", "GPTBot/1.4")
    refute AiCrawlerRanges.verified?("20.171.206.10", "Mozilla/5.0"), "not an AI crawler's agent"

    AiCrawlerRanges.refresh!(get: ->(_url) { "not json" })
    assert AiCrawlerRanges.verified?("20.171.206.10", "GPTBot/1.4"), "a failed fetch keeps the last ranges"
  end
end
