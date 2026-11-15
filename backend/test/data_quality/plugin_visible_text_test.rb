require "test_helper"
require_relative "support/dummy_plugin"

# Infra, 15 Nov: an out-of-memory kill during the nightly crawl. A plug-in
# keeps only the last source's visible text, never every page it read.
class DataQuality::PluginVisibleTextTest < ActiveSupport::TestCase
  test "only the last source's visible text is kept" do
    plugin = DummyPlugin.new
    pages = (1..3).map { |n| Source.create!(url: "https://example.com/#{n}", source_kind: "dummy", crawl_status: "ok", content_text: "<html><body><p>Page #{n}</p></body></html>", content_sha256: n.to_s) }
    assert_equal "Page 1", plugin.send(:visible_text, pages[0])
    assert_equal "Page 1", plugin.send(:visible_text, pages[0]), "the same page again: from the cache"
    pages.drop(1).each { |page| plugin.send(:visible_text, page) }
    assert_equal 1, plugin.instance_variable_get(:@visible_text).size
  end
end
