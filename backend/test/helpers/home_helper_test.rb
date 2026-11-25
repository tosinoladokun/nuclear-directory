require "test_helper"

class HomeHelperTest < ActionView::TestCase
  test "the source line names up to three real domains, then 'and more'; none, no line" do
    assert_equal "Source: nrc.gov", chart_sources(domains: %w[nrc.gov], more: false)
    assert_equal "Sources: nrc.gov and eia.gov", chart_sources(domains: %w[nrc.gov eia.gov], more: false)
    assert_equal "Sources: nrc.gov, eia.gov and doe.gov", chart_sources(domains: %w[nrc.gov eia.gov doe.gov], more: false)
    assert_equal "Sources: nrc.gov, eia.gov, doe.gov and more", chart_sources(domains: %w[nrc.gov eia.gov doe.gov], more: true)
    assert_nil chart_sources(domains: [], more: false)
    assert_nil chart_sources(nil)
  end

  test "bars and shares" do
    assert_equal 50.0, chart_bar_width(4, 8)
    assert_equal 0, chart_bar_width(1, 0)
    assert_equal "45.7%", chart_pct(45.7)
    assert_equal "30%", chart_pct(30.0)
  end
end
