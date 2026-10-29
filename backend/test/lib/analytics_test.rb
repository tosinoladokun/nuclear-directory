require "test_helper"
require_relative "../support/fake_posthog"

class AnalyticsTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  test "every event is anonymous: one shared id, no person profile, no IP or GeoIP" do
    Analytics.capture("company_viewed", slug: "terrapower")

    event = posthog.events.sole
    assert_equal "anonymous", event[:distinct_id]
    assert_equal "company_viewed", event[:event]
    assert_equal({ "slug" => "terrapower", "$process_person_profile" => false, "$geoip_disable" => true, "$ip" => nil },
      event[:properties])
  end

  test "searches are normalized and zero-result searches are flagged" do
    Analytics.track_search("  TerraPower ", results: 3)
    Analytics.track_search("sodium supplier", results: 0)

    first, second = posthog.events.map { |e| e[:properties].slice("query", "results", "zero_results", "source") }
    assert_equal({ "query" => "terrapower", "results" => 3, "zero_results" => false, "source" => "typed" }, first)
    assert_equal({ "query" => "sodium supplier", "results" => 0, "zero_results" => true, "source" => "typed" }, second)
  end

  test "a search says whether it was typed or a suggestion, and nothing else counts" do
    Analytics.track_search("HALEU", results: 4, source: "suggestion")
    Analytics.track_search("HALEU", results: 4, source: "<script>")

    assert_equal [ "suggestion", "typed" ], posthog.events.map { |e| e[:properties]["source"] }
  end

  test "blank searches aren't sent and long ones are capped" do
    Analytics.track_search("   ", results: 0)
    Analytics.track_search("x" * 500, results: 1)

    assert_equal [ 200 ], posthog.events.map { |e| e[:properties]["query"].length }
  end

  test "only known events can be sent" do
    assert_raises(ArgumentError) { Analytics.capture("clicked_ad") }
  end

  test "a PostHog failure never raises, even an ArgumentError from the client" do
    Analytics.client = FakePostHog.new(fail_with: Errno::ECONNREFUSED.new)
    assert_nil Analytics.capture("search", query: "x")

    Analytics.client = FakePostHog.new(fail_with: ArgumentError.new("bad property"))
    assert_nil Analytics.capture("search", query: "x")
  end

  test "the browser snippet sends page views and page leaves only, with query strings stripped" do
    snippet = Rails.root.join("app/javascript/analytics.js").read

    assert_includes snippet, "autocapture: false"
    assert_includes snippet, "capture_pageleave: true" # bounce rate and time on page
    assert_includes snippet, "disable_scroll_properties: true", "no scroll depth, which the privacy page doesn't mention"
    assert_includes snippet, "capture_performance: { web_vitals: true, network_timing: false }", "web vitals on (LCP, CLS, INP), per-request network timings off"
    assert_includes snippet, "before_send: sanitize"
    assert_includes snippet, 'cookieless_mode: "always"'
  end

  test "without a client nothing is sent and no key is exposed" do
    Analytics.client = nil

    assert_not Analytics.enabled?
    assert_nil Analytics.public_key
    assert_nil Analytics.capture("search", query: "x")
  end

  test "the host defaults to PostHog US" do
    previous = ENV.delete("POSTHOG_HOST")
    assert_equal "https://us.i.posthog.com", Analytics.host
  ensure
    ENV["POSTHOG_HOST"] = previous
  end
end
