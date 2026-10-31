require "application_system_test_case"
require_relative "../support/directory_builders"

# Instant search in the browser (#696): filtering the compact index on every keystroke, no /search request.
class InstantIndexTest < ApplicationSystemTestCase
  include DirectoryBuilders

  # Backend's index (SearchIndex, #698), as the browser gets it.
  INDEX = {
    v: "abc",
    tags: [ { s: "smr", n: "Small modular reactors", a: [ "small modular", "haleu" ], c: 7, i: "bucket-fuel" }, { s: "fusion", n: "Fusion", a: [], c: 3, i: "bucket-fuel" } ],
    icons: { "bucket-reactor-developers" => "<svg viewBox='0 0 1 1'></svg>", "bucket-fuel" => "<svg viewBox='0 0 1 1'></svg>", "site-plant" => "<svg viewBox='0 0 1 1'></svg>" },
    items: [
      { k: "c", s: "holtec-international", n: "Holtec International", sn: "Holtec", a: [ "Holtec Intl" ], d: "Builds casks and small modular reactors.", m: "Reactor developer · Camden, NJ", i: "bucket-reactor-developers", b: "nd-bucket--reactor-developers", c: 9 },
      { k: "c", s: "oklo", n: "Oklo", a: [ "Oklo Inc" ], d: "Develops advanced fission power plants.", m: "Reactor developer · Santa Clara, CA", i: "bucket-reactor-developers", b: "nd-bucket--reactor-developers", c: 4 },
      { k: "c", s: "centrus-energy", n: "Centrus Energy", sn: "Centrus", a: [ "LEU supplier" ], d: "Enrichment company.", m: "Enrichment · Bethesda, MD", i: "bucket-fuel", b: "nd-bucket--fuel", c: 3 },
      { k: "c", s: "nuscale-power", n: "NuScale Power", sn: "NuScale", x: [ "SMR" ], d: "Small modular reactor designer.", m: "Reactor developer · Portland, OR", i: "bucket-reactor-developers", b: "nd-bucket--reactor-developers", c: 2 },
      { k: "p", s: "davis-besse", n: "Davis-Besse Nuclear Power Station", x: [ "05000346", "EIA 6149" ], m: "Power plant · Oak Harbor, OH", i: "site-plant", c: 1 },
      { k: "p", s: "browns-ferry-nuclear-plant", n: "Browns Ferry Nuclear Plant", m: "Power reactor · Athens, AL", i: "site-plant", c: 1 }
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

  # The server search answers late, after the index: its HTML must not replace the local results.
  def stub_slow_server(delay: 2000)
    page.execute_script(<<~JS)
      const before = window.fetch
      window.fetch = (url, options) => {
        if (String(url).includes("/search?q=")) {
          window.__requests.push(String(url))
          return new Promise((resolve) => setTimeout(() => {
            const response = new Response('<turbo-frame id="search-large-frame"><div class="nd-instant" data-instant-search-count="1">STALE SERVER ANSWER</div></turbo-frame>', { headers: { "Content-Type": "text/html" } })
            Object.defineProperty(response, "url", { value: new URL(String(url), location.origin).href })
            resolve(response)
          }, #{delay}))
        }
        return before(url, options)
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
    field.send_keys("50-346")
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

  test "a slow /search answer that arrives after the index doesn't replace the local results" do
    visit root_path
    stub_index(delay: 500)
    stub_slow_server
    field = find("input[type=search]")
    field.send_keys("oklo")
    eventually { requests.any? { |url| url.include?("/search?q=oklo") } }
    assert_selector ".nd-instant__row b", text: "Oklo", wait: 10
    sleep 2.5
    assert_selector ".nd-instant__row b", text: "Oklo"
    assert_no_text "STALE SERVER ANSWER"
  end

  test "Escape on the server's results while the index is still loading keeps them closed" do
    visit root_path
    stub_index(delay: 2000)
    stub_slow_server(delay: 100)
    field = find("input[type=search]")
    field.send_keys("oklo")
    assert_selector ".nd-instant", text: "STALE SERVER ANSWER", wait: 10
    field.send_keys(:escape)
    assert_no_selector ".nd-instant", visible: true
    sleep 2.5
    assert_no_selector ".nd-instant__row", visible: true
    assert_equal "oklo", field.value

    field.send_keys(:backspace)
    assert_selector ".nd-instant__row b", text: "Oklo", wait: 10
  end

  test "an index that can't be fetched is tried once per page" do
    visit root_path
    page.execute_script("window.__requests = []; const real = window.fetch; window.fetch = (url, o) => { window.__requests.push(String(url)); return String(url).includes('/search/index.json') ? Promise.resolve(new Response('', { status: 404 })) : real(url, o) }")
    field = find("input[type=search]")
    field.send_keys("zz")
    sleep 0.5
    field.send_keys("zzz")
    sleep 0.5
    assert_equal 1, requests.count { |url| url.include?("/search/index.json") }
  end

  test "against the real index endpoint, with no stub: a topic, a company and a plant show, with their icons" do
    smr = technology("smr", "Small modular reactor")
    cite!(company("Real Smr Co", techs: [ smr ], roles: [ role("reactor_vendor") ], description: "Designs small modular reactors."))
    cite!(plant("Real Smr Plant", facility_type: "power_reactor", status: "operating", city: "Athens", state: "AL"))
    visit root_path
    field = find("input[type=search]")
    field.send_keys("smr")
    assert_selector ".nd-instant__group", text: /topics/i, wait: 15
    assert_selector ".nd-instant__row b", text: "Small modular reactors"
    assert_selector ".nd-instant__row b", text: "Real Smr Co"
    assert_selector ".nd-instant__row .nd-catsq svg", minimum: 2

    field.send_keys([ :control, "a" ], :backspace)
    field.send_keys("real smr pl")
    assert_selector ".nd-instant__row b", text: "Real Smr Plant", wait: 10
    assert_selector ".nd-instant__row .nd-catsq svg.nd-ic--20"
  end

  test "filtering 3,000 records takes a few milliseconds" do
    visit root_path
    ms = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      import("search_index").then(({ prepare, search }) => {
        const make = (n) => ({ k: n % 4 ? "c" : "p", s: `slug-${n}`, n: `Company ${n} Energy Partners`, a: [`Alias ${n}`], d: "Develops nuclear things for the industry.", m: "x", i: "k" })
        const index = prepare({ icons: {}, items: Array.from({ length: 3000 }, (_, n) => make(n)) })
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
