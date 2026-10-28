require "test_helper"
require_relative "../support/directory_builders"

class ErrorsTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  # Tests normally show Rails' debug page for errors. Turn it off so the
  # request goes through the exceptions app, as it does in production.
  setup do
    @env_config = Rails.application.env_config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    Rails.application.env_config.merge!("action_dispatch.show_exceptions" => :all, "action_dispatch.show_detailed_exceptions" => false)
  end

  teardown { Rails.application.env_config.merge!(@env_config) }

  test "an unknown page says so in the site layout, shows the address and offers search" do
    get "/no-such-page"

    assert_response :not_found
    assert_select "title", "Page not found · Nuclear Directory"
    assert_select "meta[name=robots][content=noindex]"
    assert_select "h1", "We don't have a page at this address."
    assert_select ".nd-notfound__numeral[aria-hidden=true]", "404"
    assert_select ".nd-notfound__path", "/no-such-page"
    assert_select "input#search-notfound[value='such']"
    assert_select "a[href='/']", "go to the home page"
    assert_select "main", 1
    assert_select "header.nd-sitebar + main"
  end

  test "a mistyped company or plant address suggests close matches" do
    company("Kairos Power")
    plant("Hermes 2 (Kairos Power, Oak Ridge)")
    company("Pending Power", verified: false)
    plant("Plant Vogtle")
    get "/companies/kairos-powr"

    assert_response :not_found
    assert_select "#notfound-matches", "Did you mean"
    assert_select ".nd-lines li:first-child a[href='/companies/kairos-power']", /Kairos Power/
    assert_select "body", text: /Pending Power/, count: 0
    assert_select "input#search-notfound[value='kairos powr']"

    get "/plants/vogtel"
    assert_select ".nd-lines a[href='/plants/plant-vogtle']", /Plant Vogtle/
  end

  test "an unpublished company is never suggested" do
    company("Kairos Power").unpublish!(by: "human:test")
    get "/companies/kairos-powr"

    assert_select "body", text: /Kairos Power/, count: 0
  end

  test "an address with nothing close shows no suggestions" do
    get "/zzzz-qqqq"

    assert_select "#notfound-matches", count: 0
  end

  test "other errors keep the static pages, which work even when the app is broken" do
    env = Rack::MockRequest.env_for("/500", "action_dispatch.original_path" => "/companies")
    status, _headers, body = Rails.application.config.exceptions_app.call(env)
    html = +""
    body.each { |part| html << part }

    assert_equal 500, status
    assert_equal File.read(Rails.public_path.join("500.html")), html
  end

  test "non-HTML requests get a bare 404" do
    get "/no-such-page.json"

    assert_response :not_found
    assert_empty response.body
  end
end
