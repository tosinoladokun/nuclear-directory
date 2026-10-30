require "test_helper"

class SourceTest < ActiveSupport::TestCase
  test "domain comes from the url" do
    source = Source.create!(url: "https://www.Energy.gov/ne/articles/x", source_kind: "web_page")
    assert_equal "energy.gov", source.domain
    assert source.crawl_pending?
  end

  test "url is unique" do
    dup = Source.new(url: sources(:nrc).url, source_kind: "web_page")
    assert_not dup.valid?
  end

  test "a source with evidence can't be deleted" do
    Evidence.create!(subject: organizations(:terrapower), source: sources(:nrc), found_by: "crawler")
    assert_not sources(:nrc).destroy
  end

  test "a bare homepage has one address, without the trailing slash, and a lookup with the slash finds it (#670)" do
    source = Source.create!(url: " https://www.mit.edu/ ", source_kind: "web_page")

    assert_equal "https://www.mit.edu", source.url
    assert_equal source, Source.find_by(url: "https://www.mit.edu/")
    assert_equal source, Source.find_or_create_by!(url: "https://www.mit.edu/") { |s| s.source_kind = "web_page" }
    assert_equal "https://www.orano.group/usa/en/", Source.normalize_value_for(:url, "https://www.orano.group/usa/en/"), "a path keeps its slash"
    assert_equal "https://example.com/?q=1", Source.normalize_value_for(:url, "https://example.com/?q=1")
  end
end
