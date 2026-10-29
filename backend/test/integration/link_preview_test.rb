require "test_helper"
require_relative "../support/directory_builders"

class LinkPreviewTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  def og_image = css_select("meta[property='og:image']").sole["content"]

  test "every public page carries one preview image" do
    company("Kairos Power")
    [ root_path, companies_path, company_path(slug: "kairos-power"), privacy_path ].each do |path|
      get path

      assert_select "meta[property='og:image']", 1
      assert_match %r{\Ahttp://www\.example\.com/cards/.+/\h{16}\.png\z}, og_image
      assert_select "meta[property='og:image:width'][content='1200']"
      assert_select "meta[property='og:image:height'][content='630']"
      assert_select "meta[property='og:image:alt']"
      assert_select "meta[name='twitter:card'][content=summary_large_image]"
      assert_select "meta[property='og:site_name']", 1
      assert_select "meta[property='og:title']", 1
      assert_select "meta[property='og:description']", 1
      assert_select "meta[property='og:type'][content=website]", 1
      assert_select "meta[property='og:url'][content=?]", "http://www.example.com#{path.split("?").first}"
    end
  end

  test "every public page names one canonical address, without its query" do
    cite!(company("Kairos Power"))
    cite!(plant("Plant Vogtle"))
    utm = "utm_source=example.com&utm_campaign=feed"
    {
      "#{root_path}?#{utm}" => root_url,
      "#{companies_path}?#{utm}" => companies_url,
      "#{companies_path}?category=fuel&#{utm}" => companies_url(category: "fuel"),
      "#{company_path(slug: "kairos-power")}?#{utm}" => company_url(slug: "kairos-power"),
      "#{plant_path(slug: "plant-vogtle")}?#{utm}" => plant_url(slug: "plant-vogtle"),
      "#{privacy_path}?#{utm}" => privacy_url,
      "#{disclaimer_path}?#{utm}" => disclaimer_url,
      "#{bot_path}?#{utm}" => bot_url
    }.each do |path, canonical|
      get path

      assert_response :success, path
      assert_select "link[rel=canonical]", 1
      assert_select "link[rel=canonical][href=?]", canonical
    end
  end

  test "a page's own title and description lead its preview; others fall back to the site's" do
    get privacy_path
    assert_select "meta[property='og:title'][content=?]", "Privacy · Nuclear Directory"
    assert_select "meta[property='og:description'][content^='Who makes the fuel']"
  end

  test "a company with nothing published yet still gets a plain line, never the old generic one (#292)" do
    company("Kairos Power")
    get company_path(slug: "kairos-power")
    assert_select "meta[property='og:title'][content=?]", "Kairos Power"
    assert_select "meta[property='og:description'][content=?]", "Kairos Power, a company in the US nuclear industry."
    assert_select "meta[name='description'][content=?]", "Kairos Power, a company in the US nuclear industry."
  end

  test "a category and the full listing preview with their own description, not the home page's (#246)" do
    get companies_path(category: "reactor-developers")
    line = "Companies designing reactors or developing new nuclear plants in the US, including small modular reactors and fusion."
    assert_select "meta[name='description'][content=?]", line
    assert_select "meta[property='og:description'][content=?]", line

    get companies_path
    assert_select "meta[property='og:description'][content=?]", "All companies in the US nuclear industry."
  end

  # Tosin, 29 Oct (SEO): a company's and a plant's meta description now ends in counts, sources included
  # ("3 plants, 2 deals, 12 sources"); link previews (og:description) and every other page still never talk about sourcing.
  test "preview descriptions say what's on the page, not how it's sourced (Tosin, #249)" do
    company("Kairos Power")
    cite!(plant("Zephyr Point", facility_type: "power_reactor", status: "operating", city: "Somewhere", state: "TX"))
    [ root_path, companies_path, companies_path(category: "reactor-developers"), company_path(slug: "kairos-power"),
      plant_path(slug: "zephyr-point") ].each do |path|
      get path

      assert_response :success, path
      assert_select "meta[property='og:description']", 1
      assert_select "meta[name='description']", 1
      assert_no_match(/source/i, css_select("meta[property='og:description']").first["content"], path)
      next if path.start_with?("/companies/", "/plants/")

      assert_no_match(/source/i, css_select("meta[name='description']").first["content"], path)
    end
  end

  test "a category keeps its own preview address; search and filters don't" do
    get companies_path(category: "reactor-developers", state: "CA", q: "x")
    assert_select "meta[property='og:url'][content=?]", "http://www.example.com/companies?category=reactor-developers"

    get companies_path(category: "not-a-category")
    assert_select "meta[property='og:url'][content=?]", "http://www.example.com/companies"

    get companies_path(tag: "fusion", state: "CA")
    assert_select "meta[property='og:url'][content=?]", "http://www.example.com/companies?tag=fusion"

    company("Kairos Power")
    get company_path(slug: "kairos-power", category: "fuel")
    assert_select "meta[property='og:url'][content=?]", "http://www.example.com/companies/kairos-power"
  end

  test "a plant, a company and a category show their own card; other pages the default (#245)" do
    cite!(company("Kairos Power", roles: [ role("reactor_vendor") ]))
    cite!(plant("Plant Vogtle", facility_type: "power_reactor", status: "operating", state: "GA"))
    {
      plant_path(slug: "plant-vogtle") => %r{/cards/plants/plant-vogtle/\h{16}\.png\z},
      company_path(slug: "kairos-power") => %r{/cards/companies/kairos-power/\h{16}\.png\z},
      companies_path(category: "reactor-developers") => %r{/cards/categories/reactor-developers/\h{16}\.png\z},
      companies_path => %r{/cards/default/\h{16}\.png\z},
      companies_path(category: "reactor-developers", q: "kairos") => %r{/cards/default/\h{16}\.png\z},
      companies_path(category: "plants", state: "GA") => %r{/cards/default/\h{16}\.png\z}, # filtered: not the category's count
      privacy_path => %r{/cards/default/\h{16}\.png\z}
    }.each do |path, image|
      get path
      assert_match image, og_image, path
    end

    get plant_path(slug: "plant-vogtle")
    assert_select "meta[property='og:image:alt'][content^='Plant Vogtle: Power plant']"
  end

  test "a card is a PNG cached for a year; an old address moves to the current card; a hidden page's is not found" do
    cite!(plant("Plant Vogtle", facility_type: "power_reactor", status: "operating", state: "GA"))
    get plant_path(slug: "plant-vogtle")
    path = URI(og_image).path

    get path
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "\x89PNG".b, response.body.b[0, 4]
    assert_match "max-age=#{1.year.to_i}", response.headers["Cache-Control"]
    assert_match "immutable", response.headers["Cache-Control"]
    assert_match "public", response.headers["Cache-Control"]

    get path.sub(/\h{16}\.png\z/, "0000000000000000.png")
    assert_redirected_to path

    plant("Hidden Plant", verified: false)
    get "/cards/plants/hidden-plant/0000000000000000.png"
    assert_response :not_found
    get "/cards/categories/not-a-category/0000000000000000.png"
    assert_response :not_found
  end

  test "the old fusion category's card moves to the default card its tag page uses (#281)" do
    get "/cards/categories/fusion/0000000000000000.png"
    assert_response :moved_permanently

    follow_redirect!
    assert_response :success
    assert_equal "image/png", response.media_type

    get companies_path(tag: "fusion")
    assert_match %r{/cards/default/}, og_image, "the tag page uses the default card"
  end
end
