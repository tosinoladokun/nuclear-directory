require "test_helper"

# NOINDEX is meant for preview deploys only; the live site leaves it unset.
class NoindexTest < ActionDispatch::IntegrationTest
  setup do
    @saved_noindex = ENV.delete("NOINDEX")
  end

  teardown do
    ENV.delete("NOINDEX")
    ENV["NOINDEX"] = @saved_noindex if @saved_noindex
  end

  test "the live site can be indexed" do
    get root_path

    assert_response :success
    assert_nil response.headers["X-Robots-Tag"]
  end

  test "with NOINDEX every response tells search engines to stay away" do
    ENV["NOINDEX"] = "1"

    [ root_path, rails_health_check_path, "/no-such-page" ].each do |path|
      get path
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"], path
    end
  end

  test "with NOINDEX robots.txt disallows everything and lists no sitemap" do
    ENV["NOINDEX"] = "1"

    get "/robots.txt"

    assert_response :success
    assert_equal "User-agent: *\nDisallow: /\n", response.body
  end

  test "with NOINDEX there is no llms.txt" do
    ENV["NOINDEX"] = "1"

    get "/llms.txt"

    assert_response :not_found
  end
end
