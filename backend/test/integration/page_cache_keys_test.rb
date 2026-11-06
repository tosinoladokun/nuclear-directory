require "test_helper"

# PM, 5 Nov (#737): a cached page's key must hold every request parameter
# the page reads, or one cached page answers every variant. These fail when a
# parameter is read but not keyed.
class PageCacheKeysTest < ActiveSupport::TestCase
  VIEWS = Rails.root.join("app/views")

  test "the list reads exactly DirectoryListing::FILTERS, and its cache key holds every one but the search" do
    keywords = DirectoryListing.instance_method(:initialize).parameters.map(&:last) - %i[fuzzy]
    assert_equal keywords.sort, DirectoryListing::FILTERS.sort, "a new filter goes in FILTERS, which the controller permits and the key reads"

    base = DirectoryListing.new.cache_key_parts
    (DirectoryListing::FILTERS - %i[q]).each do |name|
      listing = DirectoryListing.new
      listing.define_singleton_method(name) { "changed-#{name}" }
      assert_not_equal base, listing.cache_key_parts, "#{name} isn't in the list's cache key"
    end
  end

  test "the directory controller reads no parameter outside FILTERS but shown (keyed) and from (searches only, never cached)" do
    source = Rails.root.join("app/controllers/directory_controller.rb").read
    read = source.scan(/params\[:(\w+)\]/).flatten.map(&:to_sym).uniq
    assert_empty read - DirectoryListing::FILTERS - %i[shown from], "read but not keyed: add it to FILTERS"
    assert_includes source, "*listing.cache_key_parts, shown", "the key holds the filters and the rows shown"
  end

  test "cached page bodies read no request parameters (from only inside a search, which isn't cached)" do
    %w[companies/show.html.erb plants/show.html.erb].each do |view|
      assert_no_match(/params\[/, VIEWS.join(view).read, "#{view} is cached per record: a parameter it reads must be in its key")
    end
    list = VIEWS.join("directory/index.html.erb").read
    assert_equal [ "from" ], list.scan(/params\[:(\w+)\]/).flatten.uniq, "the list reads a parameter its key doesn't hold"
    list.scan(/^.*params\[:from\].*$/).each { |line| assert_match "searching?", line, "from is read only for a search" }
  end
end
