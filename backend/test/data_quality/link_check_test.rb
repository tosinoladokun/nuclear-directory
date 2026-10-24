require "test_helper"

class DataQuality::LinkCheckTest < ActiveSupport::TestCase
  BY = "human:tosin".freeze
  NOW = Time.utc(2026, 10, 22, 13)

  setup do
    stub_request(:get, "https://example.org/robots.txt").to_return(status: 404)
    @company = Organization.create!(name: "Linked Fission").tap { |c| c.verify!(by: BY) }
  end

  def cite(url, subject: @company)
    Source.create!(url:, source_kind: "web_page").tap { |source| Evidence.create!(subject:, source:, quote: "q", found_by: "human") }
  end

  def check(limit: 10) = DataQuality::LinkCheck.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), limit:, clock: -> { NOW }).run

  test "records each cited source's answer: ok, dead, blocked; never touches the fact" do
    ok = cite("https://example.org/ok")
    gone = cite("https://example.org/gone")
    walled = cite("https://example.org/walled")
    stub_request(:get, ok.url).to_return(body: "fine")
    stub_request(:get, gone.url).to_return(status: 404, body: "no")
    stub_request(:get, walled.url).to_return(status: 403, body: "Access Denied")

    stats = check

    assert_equal({ "checked" => 3, "dead" => [ gone.id ], "blocked" => [ walled.id ] }, stats)
    assert_equal [ "ok", 200, NOW ], ok.reload.values_at(:link_status, :link_http_status, :link_checked_at)
    assert_equal [ "dead", 404 ], gone.reload.values_at(:link_status, :link_http_status)
    assert_equal "blocked", walled.reload.link_status, "a block is never dead"
    assert @company.reload.verified?, "nothing is unpublished"
    assert_nil gone.reload.content_text, "the page isn't stored"
  end

  test "a bot challenge is blocked, whether it answers 200 or 503" do
    walled = cite("https://example.org/challenge-200")
    busy = cite("https://example.org/challenge-503")
    stub_request(:get, walled.url).to_return(status: 200, body: "Just a moment...", headers: { "cf-mitigated" => "challenge" })
    stub_request(:get, busy.url).to_return(status: 503, body: "Just a moment...", headers: { "cf-mitigated" => "challenge" })

    assert_equal [ walled.id, busy.id ].sort, check["blocked"].sort
    assert_equal [ 0, 0 ], [ walled.reload.link_failures, busy.reload.link_failures ]
  end

  test "a bot challenge on robots.txt blocks the host's sources, not fails them" do
    walled = cite("https://walled.example/page")
    stub_request(:get, "https://walled.example/robots.txt").to_return(status: 503, body: "Just a moment...", headers: { "cf-mitigated" => "challenge" })

    assert_equal [ walled.id ], check["blocked"]
  end

  test "a source cited only by a published role is checked too" do
    role = Role.create!(key: "fuel", name: "Fuel")
    fact = OrganizationRole.create!(organization: @company, role:).tap { |r| r.verify!(by: BY) }
    only_role = cite("https://example.org/role-only", subject: fact)

    assert_includes DataQuality::LinkCheck.new.due.map(&:id), only_role.id
  end

  test "an error is failing after three nights in a row, and a good answer resets it" do
    flaky = cite("https://example.org/flaky")
    stub_request(:get, flaky.url).to_return(status: 503, body: "down")

    2.times { check }
    assert_equal [ "error", 2 ], flaky.reload.values_at(:link_status, :link_failures)
    assert_equal [ flaky.id ], check["failing"]

    stub_request(:get, flaky.url).to_return(body: "back")
    check
    assert_equal [ "ok", 0 ], flaky.reload.values_at(:link_status, :link_failures)
  end

  test "only sources behind published facts, never checked first, then the oldest check, up to the night's limit" do
    rejected = Organization.create!(name: "Gone Fission").tap { |c| c.reject!(by: BY, reason: "not nuclear") }
    unpublished_only = cite("https://example.org/rejected-only", subject: rejected)
    old = cite("https://example.org/old").tap { |s| s.update_columns(link_checked_at: NOW - 3.days) }
    fresh = cite("https://example.org/new")
    recent = cite("https://example.org/recent").tap { |s| s.update_columns(link_checked_at: NOW - 1.day) }
    Source.create!(url: "https://example.org/uncited", source_kind: "web_page")

    due = DataQuality::LinkCheck.new(limit: 2).due.map(&:id)

    assert_equal [ fresh.id, old.id ], due
    refute_includes DataQuality::LinkCheck.new.due.map(&:id), unpublished_only.id
    assert_includes DataQuality::LinkCheck.new.due.map(&:id), recent.id
  end
end
