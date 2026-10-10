require "test_helper"

class PageViewCountingTest < ActionDispatch::IntegrationTest
  class PagesController < ApplicationController
    def show = render(html: "<p>page</p>".html_safe, layout: false)
    def data = render(json: { ok: true })
    def missing = head(:not_found)
  end

  BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

  def visit(path, user_agent: BROWSER, headers: {})
    get path, headers: { "User-Agent" => user_agent }.merge(headers)
  end

  def counts = UsageCount.page_view.pluck(:key, :count).to_h

  def with_pages(&)
    with_routing do |routes|
      routes.draw do
        get "companies/:id" => "page_view_counting_test/pages#show"
        get "api/data" => "page_view_counting_test/pages#data"
        get "gone" => "page_view_counting_test/pages#missing"
        get "design" => "design_system#show"
      end
      yield
    end
  end

  test "counts the path of each page a person loads, without the query string" do
    with_pages do
      visit "/companies/terrapower"
      visit "/companies/terrapower/?ref=newsletter&email=someone@example.com"
    end

    assert_equal({ "/companies/terrapower" => 2 }, counts)
  end

  test "stores nothing about the visitor and sets no cookie" do
    with_pages do
      visit "/companies/terrapower"
      assert_empty response.headers["Set-Cookie"].to_s
    end

    assert_equal %w[count created_at day event id key updated_at], UsageCount.column_names.sort
  end

  test "bots, prefetches and frame requests aren't counted" do
    with_pages do
      visit "/companies/terrapower", user_agent: "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
      visit "/companies/terrapower", user_agent: "curl/8.7.1"
      visit "/companies/terrapower", user_agent: ""
      visit "/companies/terrapower", headers: { "Sec-Purpose" => "prefetch" }
      visit "/companies/terrapower", headers: { "X-Sec-Purpose" => "prefetch" }
      visit "/companies/terrapower", headers: { "Turbo-Frame" => "results" }
    end

    assert_empty counts
  end

  test "the design page, JSON and errors aren't counted" do
    with_pages do
      visit "/design"
      visit "/api/data"
      visit "/gone"
    end

    assert_empty counts
  end

  test "the health check isn't counted" do
    visit "/up"
    assert_empty counts
  end

  test "a counting failure never breaks the page" do
    original = UsageCount.method(:track_page_view)
    UsageCount.define_singleton_method(:track_page_view) { |*| raise ActiveRecord::ConnectionNotEstablished }

    with_pages do
      visit "/companies/terrapower"
      assert_response :success
    end
  ensure
    UsageCount.define_singleton_method(:track_page_view, original)
  end
end
