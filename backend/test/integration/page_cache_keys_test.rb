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

  # The parameter names a source reads. Every mention of params must be a form this understands
  # (params[:x], params["x"], params.fetch/dig(:x), params.permit(...)), or the test fails: an unknown form
  # can't hide a read.
  def params_read(source, where)
    mentions = source.scan(/\bparams\b.{0,80}/)
    names = mentions.flat_map do |mention|
      case mention
      when /\Aparams\[\s*[:"'](\w+)/, /\Aparams\.(?:fetch|dig|key\?|has_key\?|include\?)\(\s*[:"'](\w+)/ then [ $1 ]
      when /\Aparams\.permit\(([^)]*)\)/
        $1.include?("DirectoryListing::FILTERS") ? DirectoryListing::FILTERS.map(&:to_s) : $1.scan(/:(\w+)/).flatten
      else flunk "#{where}: can't tell which parameter this reads: #{mention.strip}"
      end
    end
    names.map(&:to_sym).uniq
  end

  test "the directory controller reads no parameter outside FILTERS but shown (keyed) and from (searches only, never cached)" do
    source = Rails.root.join("app/controllers/directory_controller.rb").read
    assert_empty params_read(source, "directory_controller") - DirectoryListing::FILTERS - %i[shown from], "read but not keyed: add it to FILTERS"
    assert_includes source, "*listing.cache_key_parts, shown", "the key holds the filters and the rows shown"
  end

  test "cached page bodies read no request parameters; the list view only from" do
    %w[companies/show.html.erb plants/show.html.erb].each do |view|
      assert_no_match(/\bparams\b/, VIEWS.join(view).read, "#{view} is cached per record: it may read no parameter")
    end
    assert_equal %i[from], params_read(VIEWS.join("directory/index.html.erb").read, "directory/index")
  end
end

# from=suggestion marks a search from a home suggestion; a browse page (cached) must look the same with or
# without it, whichever request fills the cache first.
class PageCacheFromParamTest < ActionDispatch::IntegrationTest
  setup do
    @store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @caching, ActionController::Base.perform_caching = ActionController::Base.perform_caching, true
    DataVersion.expire!
    Organization.create!(name: "From Co", slug: "from-co", verification_status: "verified", verified_by: "human:tosin")
  end

  teardown do
    Rails.cache = @store
    ActionController::Base.perform_caching = @caching
    DataVersion.expire!
  end

  def page(path)
    get path
    assert_response :success
    response.body.gsub(/<meta name="csrf-token" content="[^"]+"/, "")
  end

  def uncached(path)
    ActionController::Base.perform_caching = false
    page(path)
  ensure
    ActionController::Base.perform_caching = true
  end

  test "a browse page (all companies, plants) with and without from=suggestion matches its uncached render, in both cache-fill orders" do
    Facility.create!(name: "From Station", slug: "from-station", facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    %w[/companies /companies?category=plants].each do |browse|
      with_from = "#{browse}#{browse.include?('?') ? '&' : '?'}from=suggestion"
      [ [ browse, with_from ], [ with_from, browse ] ].each do |order|
        Rails.cache.clear
        order.each { |path| assert_equal uncached(path), page(path), "#{path} after #{order.first}" }
      end
    end
  end
end
