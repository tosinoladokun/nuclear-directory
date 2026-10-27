require "test_helper"

class DataQuality::Plugins::FirstReadPagesTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::FirstReadPages

  setup do
    stub_request(:get, %r{/robots\.txt\z}).to_return(status: 404)
    Plugin::PAGES.each_key { |url| stub_request(:get, url).to_return(body: "<html><main>Page #{url}</main></html>") }
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))

  test "is the plug-in for first_read_pages, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("first_read_pages")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "first_read_pages"
  end

  test "stores each page as it comes, once a day, and proposes nothing" do
    stats = DataQuality::Stages::Crawl.call(plugin:).stats
    assert_equal Plugin::PAGES.size, stats.values.count("changed")
    Plugin::PAGES.each_key { |url| assert_match "Page #{url}", Source.find_by!(url:).content_text }
    assert_empty plugin.extract(Source.find_by!(url: Plugin::PAGES.keys.first), nil)
    assert_equal Plugin::PAGES.size, DataQuality::Stages::Crawl.call(plugin:).stats.values.count("skipped_recent")
  end

  test "a block is recorded" do
    stub_request(:get, Plugin::PAGES.keys.first).to_return(status: 403, body: "Access Denied")
    assert_equal "blocked", DataQuality::Stages::Crawl.call(plugin:).stats.values.first
  end
end
