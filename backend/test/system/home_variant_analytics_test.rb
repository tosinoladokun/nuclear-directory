require "application_system_test_case"
require_relative "../support/directory_builders"

# What the home page's analytics send for the A/B test (#909), checked on the real page through the module's own
# helpers (PostHog isn't loaded in tests).
class HomeVariantAnalyticsTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    cite!(company("Kairos Power", roles: [ role("reactor_vendor") ]))
    fuel = role("fuel")
    cite!(company("Centrus Energy", roles: [ role("enrichment", parent: fuel) ])) # a whole chart set, so B shows (#909)
    %w[mining conversion fabrication].each { |key| role(key, parent: fuel) }
  end

  def run_module(body)
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("analytics").then((m) => done(JSON.stringify((() => { #{body} })()))).catch((e) => done(String(e)))
    JS
  end

  test "home events wait for PostHog, in order; once per view; Back's restored copy is no new view (#918 review)" do
    visit root_path
    result = JSON.parse(run_module(<<~JS))
      m.installHomeTracking()
      const field = document.querySelector("#search-large")
      for (const text of ["k", "ka"]) { field.value = text; field.dispatchEvent(new Event("input", { bubbles: true })) }
      const before = m.pendingHomeEvents().map((event) => event[0])
      document.documentElement.replaceChild(document.body.cloneNode(true), document.body) // what Back restores
      m.trackHomeView()
      const afterBack = m.pendingHomeEvents().length
      const sent = []
      m.homeReady({ capture: (name, properties) => sent.push([ name, properties.home_variant ]) })
      return { before, afterBack, sent, left: m.pendingHomeEvents().length }
    JS
    assert_equal %w[home_viewed home_search_started], result["before"], "a search before PostHog loads waits, after the view"
    assert_equal 2, result["afterBack"], "the restored copy carries its mark"
    assert_equal [ %w[home_viewed A], %w[home_search_started A] ], result["sent"]
    assert_equal 0, result["left"]
  end

  test "the home page view and a card click carry the version; a forced visit says so; other pages carry none" do
    visit root_path
    result = JSON.parse(run_module(<<~JS))
      const card = document.querySelector("a.nd-catcard__link")
      return {
        variant: m.homeVariantProperties(),
        view: m.sanitize({ event: "$pageview", properties: { $pathname: "/" } }).properties,
        elsewhere: m.sanitize({ event: "$pageview", properties: { $pathname: "/companies/kairos-power" } }).properties,
        click: m.categoryClickProperties(card)
      }
    JS
    assert_equal({ "home_variant" => "A" }, result["variant"])
    assert_equal({ "$pathname" => "/", "home_variant" => "A" }, result["view"])
    assert_equal({ "$pathname" => "/companies/kairos-power" }, result["elsewhere"], "only the home page view is tagged")
    assert_equal({ "category" => "reactor-developers", "from" => "card" }, result["click"])

    visit root_path(home: "b")
    assert_equal({ "home_variant" => "B", "home_variant_forced" => true }, JSON.parse(run_module("return m.homeVariantProperties()")))

    page.execute_script("document.querySelector('meta[name=home-variant]').dataset.fallback = 'true'") # what the server writes when B falls back
    assert_equal({ "home_variant" => "B", "home_variant_forced" => true, "home_fallback" => true }, JSON.parse(run_module("return m.homeVariantProperties()")))

    visit "/companies"
    assert_nil JSON.parse(run_module("return m.homeVariantProperties()"))
  end
end
