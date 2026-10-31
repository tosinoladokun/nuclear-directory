require "test_helper"

# The icons and topic pages instant search dresses its rows with (#696).
class SearchExtrasTest < ActionDispatch::IntegrationTest
  test "icons for the rows (company 16px, plant 20px) and the topic pages a typed word can open" do
    get search_extras_path
    assert_response :success
    assert_equal "application/json", response.media_type
    body = JSON.parse(response.body)

    assert_includes body["icons"].keys, "bucket-fuel"
    assert_includes body["icons"].keys, "site-plant"
    assert_includes body["icons"].keys, "site-plant@20"
    assert_includes body["icons"].keys, "buildings"
    assert body["icons"]["site-plant@20"].include?("nd-ic--20")
    assert_nil response.headers["Set-Cookie"], "no session cookie, so a shared cache may keep it"
    assert_match(/public/, response.headers["Cache-Control"])
    Array(body["tags"]).each { |tag| assert_includes body["icons"].keys, tag["i"], "every topic's icon is in the map" }
  end
end
