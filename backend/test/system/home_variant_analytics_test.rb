require "application_system_test_case"
require_relative "../support/directory_builders"

# What the home page's analytics send for the A/B test (#909), checked on the real page through the module's own
# helpers (PostHog isn't loaded in tests).
class HomeVariantAnalyticsTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup { cite!(company("Kairos Power", roles: [ role("reactor_vendor") ])) }

  def run_module(body)
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("analytics").then((m) => done(JSON.stringify((() => { #{body} })()))).catch((e) => done(String(e)))
    JS
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

    visit "/companies"
    assert_nil JSON.parse(run_module("return m.homeVariantProperties()"))
  end
end
