require "test_helper"
require_relative "support/dummy_plugin"

# #240: a person decides a fact once; afterwards the crawler only records
# that its source still says the same thing.
class DataQuality::ReconfirmTest < ActiveSupport::TestCase
  include ReviewHelpers

  # A table of operating units, like NRC's list: one row per unit, with a
  # "generated" line that changes on every read (NRC's page has a date stamp).
  class TablePlugin < DataQuality::Plugin
    URL = "https://example.com/units"
    attr_reader :extracts

    def initialize = @extracts = 0
    def source_kind = "units_table"
    def crawl(_run) = {}

    def extract(source, _run)
      @extracts += 1
      rows(source).flat_map do |row|
        name, docket, status, operator = row.split(" | ")
        unit = { "name" => name, "nrc_docket" => docket }
        [
          { kind: "facility", quote: row, payload: unit.merge("facility_type" => "power_reactor", "status" => status) },
          { kind: "organization", quote: row, payload: { "name" => operator } },
          { kind: "facility_relationship", quote: row,
            payload: { "organization" => { "name" => operator }, "facility" => unit, "relationship_type" => "operates" } }
        ]
      end
    end

    def rows_sha256(source) = Digest::SHA256.hexdigest(rows(source).join("\n"))
    def dropped(kind) = ([ { "status" => "shut_down" }, "Approve to mark it shut down." ] if kind == "facility")
    def quote_in_source?(source, quote) = rows(source).include?(quote)

    private
      def rows(source) = source.content_text.to_s.lines(chomp: true).reject { |line| line.start_with?("#") }
  end

  # Five units, so dropping one stays within the dropped check's quarter.
  ROWS = (1..5).map { |n| "Zephyr Point #{n} | 0509900#{n} | operating | Zephyr Nuclear Co" }.freeze
  BY = "human:tosin"

  setup { @plugin = TablePlugin.new }

  def source = Source.find_by!(url: TablePlugin::URL)

  # A read of the table on a given day: the rows, and the line that changes daily.
  def read!(rows = ROWS, on: Time.current)
    text = [ *rows, "# generated #{on.iso8601}" ].join("\n")
    Source.find_or_initialize_by(url: TablePlugin::URL).update!(source_kind: "units_table", crawl_status: "ok", content_text: text,
      content_sha256: Digest::SHA256.hexdigest(text), fetched_at: on, http_status: 200)
  end

  def pipeline! = DataQuality::Pipeline.run("units_table", plugin: @plugin, only: %w[extract match verify], verifier: PublishEverything.new)

  # Everything the first read found, approved by a person.
  def first_read_approved!
    read!(on: 2.days.ago)
    pipeline!
    approve_recommended.each { |result| assert result.ok?, result.errors.join }
    assert_empty queue, "all approved"
  end

  # What waits for a person.
  def queue = Candidate.where(source: Source.where(source_kind: "units_table"), status: %w[new matched needs_review])

  def unit(docket) = Facility.find_by!(nrc_docket: docket)

  test "a read that no longer has a fact's quote never records the fact as checked" do
    first_read_approved!
    evidence = Evidence.where(source: source)
    checked = evidence.pluck(:id, :last_confirmed_at).to_h

    read!([], on: 1.day.ago) # the table now names nothing: no candidates
    pipeline!
    read!([], on: 1.hour.ago) # and reads the same again
    pipeline!

    assert_equal checked, evidence.pluck(:id, :last_confirmed_at).to_h, "the old quotes are gone, so nothing was re-checked"
  end

  test "a second read of an unchanged table queues nothing and records when it was checked" do
    first_read_approved!
    events = VerificationEvent.count

    read!(on: 1.hour.ago) # a new page: only its date line changed
    runs = pipeline!

    assert_equal 1, @plugin.extracts, "the same rows aren't extracted again"
    assert_equal 1, runs.first.stats["rows_unchanged"]
    assert_empty queue
    assert_equal events, VerificationEvent.count, "nothing added to any fact's history"
    evidence = unit("05099001").evidence.find_by!(source: source)
    assert_in_delta 1.hour.ago, evidence.last_confirmed_at, 1.second
    assert_equal @plugin.rows_sha256(source), evidence.confirmed_sha256
  end

  test "rows read again that say the same thing are confirmed, not queued, and history stays clean" do
    first_read_approved!
    events = VerificationEvent.count

    read!(ROWS.reverse, on: 1.hour.ago) # the same rows, in another order: read again
    runs = pipeline!

    assert_equal 2, @plugin.extracts
    assert_empty queue, "0 review items"
    assert_equal 11, runs.second.stats["confirmed"], "5 units, the company (one claim for all its rows) and 5 links"
    assert Candidate.where(source:, status: "confirmed").all? { |c| c.notes.start_with?("Confirmed: the source still says") }
    assert_equal events, VerificationEvent.count
  end

  test "a value a person overruled stays out of review; their decision stands" do
    first_read_approved!
    DataQuality::Review.approve_fact(type: "Facility", id: unit("05099001").id, by: BY, reason: "Shut down on 1 Oct",
      attributes: { "status" => "shut_down" })

    read!(ROWS.reverse, on: 1.hour.ago)
    pipeline!

    assert_empty queue, "the source still says operating, which the person already overruled"
    confirmed = Candidate.where(source:, kind: "facility", status: "confirmed").find { |c| c.payload["nrc_docket"] == "05099001" }
    assert_match "a person's decision stands: status shut_down (it says operating)", confirmed.notes
    assert_equal "shut_down", unit("05099001").status
  end

  test "a real change goes to review with the published value next to the new one" do
    first_read_approved!

    read!([ ROWS.first.sub("operating", "shut_down"), *ROWS.drop(1) ], on: 1.hour.ago)
    pipeline!

    changed = queue.find_by!(kind: "facility")
    assert changed.status_needs_review?
    assert_equal "human-verified status is operating; this source says shut_down", changed.notes
    # The row's company and link claims now quote text the source didn't have:
    # a person approves them, adding the current quote, rather than the old one being marked re-checked.
    assert_equal %w[facility_relationship organization], queue.where.not(kind: "facility").pluck(:kind).sort
    assert queue.where.not(kind: "facility").all?(&:status_matched?)
  end

  test "a fact a person unpublished, stated again unchanged, stays unpublished without a review item" do
    first_read_approved!
    link = unit("05099001").facility_relationships.sole
    DataQuality::Review.unpublish(type: "FacilityRelationship", id: link.id, by: BY, reason: "Checking the operator")

    read!(ROWS.reverse, on: 1.hour.ago)
    pipeline!

    assert_empty queue
    assert link.reload.unpublished?
    assert_match "it stays unpublished", Candidate.where(source:, subject: link, status: "confirmed").sole.notes
  end

  test "a published fact a complete read no longer lists is flagged once, suggesting the plugin's change" do
    first_read_approved!

    read!(ROWS.first(4), on: 1.hour.ago)
    pipeline!

    flags = queue.where(review_origin: "dropped")
    assert_equal [ [ "Facility", unit("05099005").id ], [ "FacilityRelationship", unit("05099005").facility_relationships.sole.id ] ],
      flags.order(:subject_type).pluck(:subject_type, :subject_id)
    flag = flags.find_by!(kind: "facility")
    assert_equal({ "status" => "shut_down" }, flag.payload)
    assert_match "No longer in", flag.notes
    assert unit("05099005").verified?, "never unpublished automatically"

    pipeline!
    assert_equal 2, queue.where(review_origin: "dropped").count, "not flagged again"
  end

  test "a read that would drop more than a quarter of what it supported flags nothing: likely a broken page" do
    first_read_approved!

    read!(ROWS.first(3), on: 1.hour.ago) # 2 units and their links: 4 of 11 facts
    runs = pipeline!

    assert_empty queue.where(review_origin: "dropped")
    assert_equal 1, runs.second.stats["dropped_check_skipped"]
  end

  test "an unchanged read stamps only what its rows still support; a failed fetch stamps nothing" do
    first_read_approved!
    read!(ROWS.first(4), on: 2.hours.ago) # unit 5 dropped
    pipeline!

    read!(ROWS.first(4), on: 1.hour.ago) # the same rows again
    pipeline!

    assert_in_delta 1.hour.ago, unit("05099001").evidence.find_by!(source:).last_confirmed_at, 1.second
    assert_nil unit("05099005").evidence.find_by!(source:).last_confirmed_at, "the rows no longer list it"

    source.update!(fetched_at: Time.current, status_reason: "Timed out") # a failed fetch keeps the old content
    pipeline!
    assert_in_delta 1.hour.ago, unit("05099001").evidence.find_by!(source:).last_confirmed_at, 1.second
  end

  test "a link to a plant a person unpublished, stated again unchanged, is confirmed and not written" do
    first_read_approved!
    link = unit("05099001").facility_relationships.sole
    DataQuality::Review.unpublish(type: "Facility", id: unit("05099001").id, by: BY, reason: "Checking it")

    read!(ROWS.reverse, on: 1.hour.ago)
    pipeline!

    assert_empty queue
    assert_match "it stays verified", Candidate.where(source:, subject: link, status: "confirmed").sole.notes
    assert unit("05099001").unpublished?
  end

  test "a link to a unit whose site a person unpublished, stated again unchanged, is confirmed and not written" do
    first_read_approved!
    site = Facility.create!(name: "Zephyr Point", verification_status: "verified", verified_by: BY)
    unit("05099001").update!(parent: site)
    DataQuality::Review.unpublish(type: "Facility", id: site.id, by: BY, reason: "Checking it")
    link = unit("05099001").facility_relationships.sole

    read!(ROWS.reverse, on: 1.hour.ago)
    pipeline!

    assert_empty queue
    assert_equal "confirmed", Candidate.where(source:, subject: link).order(:id).last.status
  end

  test "a repeat of a pending claim whose row now reads differently replaces the waiting one" do
    read!(on: 2.hours.ago)
    pipeline!
    waiting = queue.where(kind: "facility").find { |c| c.payload["nrc_docket"] == "05099001" }

    # The same values, but the row now carries another column (NRC's license field, say).
    read!([ "#{ROWS.first} | NPF-1", *ROWS.drop(1) ], on: 1.hour.ago)
    pipeline!

    assert_equal "confirmed", waiting.reload.status
    assert_match "the source's row now reads differently", waiting.notes
    current = queue.where(kind: "facility").find { |c| c.payload["nrc_docket"] == "05099001" }
    assert_equal "#{ROWS.first} | NPF-1", current.quote, "the one quoting the source as it reads now waits"
  end

  test "nothing is confirmed against a page whose last fetch failed" do
    first_read_approved!
    read!(ROWS.reverse, on: 1.hour.ago)
    DataQuality::Pipeline.run("units_table", plugin: @plugin, only: %w[extract])
    source.update!(status_reason: "Timed out", fetched_at: Time.current) # the next fetch failed; the old content stays

    DataQuality::Pipeline.run("units_table", plugin: @plugin, only: %w[match])

    assert_equal 0, Candidate.where(source:, status: "confirmed").count
    assert_nil unit("05099001").evidence.find_by!(source:).last_confirmed_at
  end

  test "a restated link is attached without writing to it" do
    first_read_approved!
    link = unit("05099001").facility_relationships.sole
    touched = link.updated_at

    read!(ROWS.reverse, on: 1.hour.ago)
    pipeline!

    assert_equal touched, link.reload.updated_at, "no save, no confidence recompute, no snapshot expiry"
  end

  test "a person's decision made while match confirms the candidate is kept" do
    first_read_approved!
    candidate = Candidate.where(source:, status: "merged", kind: "facility").first
    repeat = Candidate.create!(source:, kind: "facility", quote: candidate.quote, payload: candidate.payload, status: "matched",
      subject: candidate.subject)
    Candidate.where(id: repeat.id).update_all(status: "rejected", notes: "Rejected by a person meanwhile")
    match = DataQuality::Stages::Match.new(plugin: @plugin)
    match.instance_variable_set(:@stats, { "matched" => 1 })

    match.send(:confirmed, repeat, DataQuality::DirectoryClient.new.attached_record(repeat), "Confirmed")

    assert_equal [ "rejected", "Rejected by a person meanwhile" ], [ repeat.reload.status, repeat.notes ]
  end

  test "a source extracted before rows were hashed gets its hash, and its evidence stamped, on the next unchanged read" do
    first_read_approved!
    source.update_columns(extracted_rows_sha256: nil, fetched_at: 1.hour.ago)

    runs = DataQuality::Pipeline.run("units_table", plugin: @plugin, only: %w[extract])

    assert_equal 1, runs.first.stats["unchanged"]
    assert_equal @plugin.rows_sha256(source), source.reload.extracted_rows_sha256
    assert_in_delta 1.hour.ago, unit("05099001").evidence.find_by!(source:).last_confirmed_at, 1.second
  end

  test "a blocked or unread page flags nothing as dropped" do
    first_read_approved!
    read!(ROWS.first(4), on: 1.hour.ago)
    source.update!(crawl_status: "blocked")

    pipeline!
    assert_empty queue.where(review_origin: "dropped")

    source.update!(crawl_status: "ok")
    DataQuality::Pipeline.run("units_table", plugin: @plugin, only: %w[match])
    assert_empty queue.where(review_origin: "dropped"), "the new page isn't extracted yet, so nothing is known missing"
  end

  # As run 21 left them (before #240): identical claims matched and waiting.
  def waiting_like_run_21
    Candidate.where(source:, status: "merged").map do |merged|
      Candidate.create!(source:, kind: merged.kind, payload: merged.payload, quote: merged.quote, status: "matched",
        subject_type: merged.subject_type, subject_id: merged.subject_id)
    end
  end

  test "the one-off closes waiting identical candidates as confirmed, as the named person, after a dry run" do
    first_read_approved!
    waiting = waiting_like_run_21
    different = Candidate.create!(source:, kind: "facility", quote: ROWS.first, status: "matched", subject: unit("05099001"),
      payload: { "name" => "Zephyr Point 1", "nrc_docket" => "05099001", "status" => "shut_down" })
    events = VerificationEvent.count

    dry = DataQuality::Review.confirm_identical(by: BY, dry_run: true)
    assert_equal waiting.size, dry.count(&:ok?)
    assert waiting.all? { |c| c.reload.status_matched? }, "a dry run changes nothing"
    assert_nil unit("05099001").evidence.find_by!(source:).last_confirmed_at

    results = DataQuality::Review.confirm_identical(by: BY)

    assert waiting.all? { |c| c.reload.status_confirmed? && c.reviewed_by == BY }
    assert_match "Confirmed by human:tosin: identical to", waiting.first.notes
    assert different.reload.status_matched?
    assert_match "it differs: status operating → shut_down", results.find { |r| r.candidate_id == different.id }.errors.join
    assert_equal events, VerificationEvent.count, "no 'verified again' event on any fact"
  end

  test "the one-off leaves a fact still waiting for its first decision to a person" do
    read!
    pipeline!

    results = DataQuality::Review.confirm_identical(by: BY)

    assert results.none?(&:ok?)
    assert_match "isn't decided yet", results.first.errors.join
    assert_raises(ArgumentError) { DataQuality::Review.confirm_identical(by: "agent:x") }
  end

  test "a link claim attached to another plant's link (#226) isn't confirmed, and stamps nothing" do
    first_read_approved!
    other_link = unit("05099002").facility_relationships.sole
    # "Zephyr Nuclear Co operates Zephyr Point 1", attached to Zephyr Point 2's link, with that link's quote.
    misattached = Candidate.create!(source:, kind: "facility_relationship", quote: ROWS.second, status: "matched", subject: other_link,
      payload: { "organization" => { "name" => "Zephyr Nuclear Co" }, "facility" => { "name" => "Zephyr Point 1", "nrc_docket" => "05099001" },
        "relationship_type" => "operates" })
    stamped = other_link.evidence.pluck(:last_confirmed_at)

    result = DataQuality::Review.confirm_identical([ misattached.id ], by: BY).sole

    assert_match "it differs: facility Zephyr Point 2 → Zephyr Point 1", result.errors.join
    assert misattached.reload.status_matched?
    assert_equal stamped, other_link.evidence.reload.pluck(:last_confirmed_at)
  end

  test "the one-off leaves a 'no longer listed' flag for a person" do
    first_read_approved!
    read!(ROWS.first(4), on: 1.hour.ago)
    pipeline!
    flag = queue.find_by!(review_origin: "dropped", kind: "facility_relationship")

    DataQuality::Review.confirm_identical(by: BY)

    assert flag.reload.status_needs_review?
  end

  test "a company named on several rows is one claim" do
    read!

    pipeline!

    assert_equal 1, Candidate.where(source:, kind: "organization").count
  end
end
