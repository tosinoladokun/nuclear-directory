require "application_system_test_case"

# Instant search in the browser (#696): filtering the compact index on every keystroke, no /search request.
class InstantIndexTest < ApplicationSystemTestCase
  INDEX = {
    icons: { "bucket-fuel" => "<svg viewBox='0 0 1 1'></svg>", "site-plant" => "<svg viewBox='0 0 1 1'></svg>" },
    tags: [ { s: "smr", n: "Small modular reactors", a: [ "small modular", "haleu" ], c: 7, i: "bucket-fuel" }, { s: "fusion", n: "Fusion", a: [], c: 3, i: "bucket-fuel" } ],
    items: [
      { k: "c", s: "holtec-international", n: "Holtec International", sn: "Holtec", a: [ "Holtec Intl" ], d: "Builds casks and small modular reactors.", m: "Reactor developer · Camden, NJ", i: "bucket-fuel", b: "nd-bucket--fuel", c: 9 },
      { k: "c", s: "oklo", n: "Oklo", sn: nil, a: [ "Oklo Inc" ], d: "Develops advanced fission power plants.", m: "Reactor developer · Santa Clara, CA", i: "bucket-fuel", b: nil, c: 4 },
      { k: "c", s: "centrus-energy", n: "Centrus Energy", sn: "Centrus", a: [ "LEU supplier" ], d: "Enrichment company.", m: "Enrichment · Bethesda, MD", i: "bucket-fuel", b: nil, c: 3 },
      { k: "c", s: "nuscale-power", n: "NuScale Power", sn: "NuScale", a: [], x: [ "SMR" ], d: "Small modular reactor designer.", m: "Reactor developer · Portland, OR", i: "bucket-fuel", b: nil, c: 5 },
      { k: "p", s: "davis-besse", n: "Davis-Besse Nuclear Power Station", sn: nil, a: [], x: [ "05000346", "EIA 6149" ], d: nil, m: "Power reactor · Oak Harbor, OH", i: "site-plant", b: nil, c: 1 },
      { k: "p", s: "browns-ferry-nuclear-plant", n: "Browns Ferry Nuclear Plant", sn: nil, a: [], d: nil, m: "Power reactor · Athens, AL", i: "site-plant", b: nil, c: 2 }
    ]
  }.freeze

  def stub_index(delay: 0)
    page.execute_script(<<~JS)
      window.__requests = []
      const real = window.fetch
      window.fetch = (url, options) => {
        window.__requests.push(String(url))
        if (String(url).includes("/search/index.json")) return new Promise((resolve) => setTimeout(() => resolve(new Response(#{INDEX.to_json.to_json}, { headers: { "Content-Type": "application/json" } })), #{delay}))
        return real(url, options)
      }
    JS
  end

  def requests = page.evaluate_script("window.__requests")

  test "typing filters the index in the browser: aliases, grouped results, close spellings, Enter goes to the full results" do
    visit root_path
    stub_index
    field = find("input[type=search]")
    field.click
    eventually { requests.any? { |url| url.include?("/search/index.json") } }

    field.send_keys("oklo inc")
    assert_selector ".nd-instant__row", text: "Oklo", wait: 10
    assert_selector ".nd-instant__group", text: /companies/i

    find("input[type=search]").send_keys([ :control, "a" ], :backspace)
    field.send_keys("holtec intl")
    assert_selector ".nd-instant__row b", text: "Holtec International"

    find("input[type=search]").send_keys([ :control, "a" ], :backspace)
    field.send_keys("browns")
    assert_selector ".nd-instant__group", text: /plants and sites/i
    assert_selector ".nd-instant__row", text: "Athens, AL"

    find("input[type=search]").send_keys([ :control, "a" ], :backspace)
    field.send_keys("browns fery")
    assert_selector ".nd-instant__note", text: "No exact match"
    assert_selector ".nd-instant__row b", text: "Browns Ferry Nuclear Plant"

    assert_not requests.any? { |url| url.include?("/search?q=") }, "no request per keystroke: #{requests.inspect}"

    find("input[type=search]").send_keys([ :control, "a" ], :backspace)
    field.send_keys("centrus")
    assert_selector ".nd-instant__all", text: "All results for “centrus”"
    field.send_keys(:enter)
    assert_current_path(/\/companies\?.*q=centrus/)
  end

  test "IDs find their record, and topic words jump to the tag page" do
    visit root_path
    stub_index
    field = find("input[type=search]")
    field.send_keys("05000346")
    assert_selector ".nd-instant__row b", text: "Davis-Besse Nuclear Power Station", wait: 10

    field.send_keys([ :control, "a" ], :backspace)
    field.send_keys("smr")
    assert_selector ".nd-instant__group", text: /topics/i
    assert_selector ".nd-instant__row b", text: "NuScale Power"
    find(".nd-instant__row", text: "Small modular reactors").click
    assert_current_path(/\/companies\?tag=smr/)
  end

  test "no results offers the correction form" do
    visit root_path
    stub_index
    find("input[type=search]").send_keys("zzzqqq")
    assert_selector ".nd-instant__empty", text: /No results for/
    assert_selector ".nd-instant__empty a[href*='corrections/new'][href*='A+missing+company'][rel=nofollow]", text: /Report a correction/
  end

  test "ranking: an exact or prefix name beats an alias, which beats a description match" do
    visit root_path
    stub_index
    field = find("input[type=search]")
    field.send_keys("energy")
    assert_selector ".nd-instant__row", wait: 10
    assert_equal "Centrus Energy", all(".nd-instant__row b").first.text

    field.send_keys([ :control, "a" ], :backspace)
    field.send_keys("reactors")
    assert_selector ".nd-instant__row b", text: "Holtec International", wait: 10
  end

  test "until the index is there, typing still searches on the server" do
    visit root_path
    stub_index(delay: 3000)
    field = find("input[type=search]")
    field.send_keys("zz")
    eventually { requests.any? { |url| url.include?("/search?q=zz") } }
    assert true
  end

  test "filtering 3,000 records takes a few milliseconds" do
    visit root_path
    ms = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      import("search_index").then(({ prepare, search }) => {
        const items = Array.from({ length: 3000 }, (_, n) => ({ k: n % 4 ? "c" : "p", s: `slug-${n}`, n: `Company ${n} Energy Partners`, sn: null, a: [`Alias ${n}`], d: "Develops nuclear things for the industry.", m: "x", i: "k", c: n }))
        const index = prepare({ icons: {}, items })
        const started = performance.now()
        ;["ene", "energy part", "compny 12", "zzzz"].forEach((query) => search(index, query))
        done((performance.now() - started) / 4)
      })
    JS
    assert_operator ms, :<, 30, "each search took #{ms.round(1)} ms"
  end

  def eventually(wait: 10)
    page.document.synchronize(wait) { raise Capybara::ExpectationNotMet, "condition not met" unless yield }
  end
end
