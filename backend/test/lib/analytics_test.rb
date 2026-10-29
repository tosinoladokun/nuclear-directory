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
    assert_includes snippet, 'web_vitals_allowed_metrics: [ "LCP", "CLS", "INP" ]', "exactly three vitals, whatever the dashboard lists"
    assert_includes snippet, "network_timing: false", "no per-request timings"
    assert_includes snippet, "before_send: sanitize"
    assert_includes snippet, 'cookieless_mode: "always"'
  end

  test "web vitals events keep their numbers but lose the nested detail objects and every query string" do
    skip "node isn't installed" unless system("which node > /dev/null 2>&1")
    script = <<~JS
      import { sanitize } from "./app/javascript/analytics.js"
      const event = sanitize({ event: "$web_vitals", properties: {
        $web_vitals_LCP_value: 1900, $current_url: "https://x.org/companies?q=me@example.com#a",
        $web_vitals_LCP_event: { $current_url: "https://x.org/companies?q=me@example.com", navigationURL: "https://x.org/c?q=1", name: "LCP" } } })
      console.log(JSON.stringify(event.properties))
    JS
    out = IO.popen([ "node", "--input-type=module", "-e", script, chdir: Rails.root.to_s ], &:read)
    props = JSON.parse(out)

    assert_equal 1900, props["$web_vitals_LCP_value"]
    assert_equal "https://x.org/companies", props["$current_url"]
    assert_not_includes out, "example.com", "no query string anywhere"
    assert_not props.key?("$web_vitals_LCP_event"), "the nested detail object is dropped"
  end

  test "outbound clicks send the kind, the destination's domain and the page's slug, never a URL or a query string (#492)" do
    snippet = Rails.root.join("app/javascript/analytics.js").read
    assert_includes snippet, 'ready.capture("outbound_click", properties, { send_instantly: true })'

    skip "node isn't installed" unless system("which node > /dev/null 2>&1")
    script = <<~JS
      import { outboundProperties } from "./app/javascript/analytics.js"
      const here = { href: "https://nuclear-directory.org/companies/oklo", host: "nuclear-directory.org", pathname: "/companies/oklo" }
      const link = (href, outbound) => ({ href, dataset: outbound ? { outbound } : {} })
      console.log(JSON.stringify([
        outboundProperties(link("https://www.oklo.com/news?utm_source=nuclear-directory&utm_campaign=company-page&q=me@x.com"), here),
        outboundProperties(link("https://www.nrc.gov/docs/ML1.pdf?email=a@b.c", "source"), here),
        outboundProperties(link("https://nuclear-directory.org/companies/kairos-power"), here),
        outboundProperties(link("mailto:hello@nuclear-directory.org"), here),
        outboundProperties(link("https://example.org/x"), { href: "https://nuclear-directory.org/search?q=me@x.com", host: "nuclear-directory.org", pathname: "/search" })
      ]))
    JS
    company, source, internal, mail, from_search = JSON.parse(IO.popen([ "node", "--input-type=module", "-e", script, chdir: Rails.root.to_s ], &:read))

    assert_equal({ "kind" => "company_website", "target_domain" => "oklo.com", "from_slug" => "oklo", "from_type" => "company" }, company)
    assert_equal({ "kind" => "source", "target_domain" => "nrc.gov", "from_slug" => "oklo", "from_type" => "company" }, source)
    assert_nil internal, "a link inside the site isn't outbound"
    assert_nil mail
    assert_equal({ "kind" => "other", "target_domain" => "example.org", "from_slug" => nil, "from_type" => "other" }, from_search)
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
