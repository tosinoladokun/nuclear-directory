require "test_helper"
require "rake"

# Change status (#316): a plant's or unit's status from its page, with
# evidence, through the same code as `directory:set_status`.
class Admin::StatusChangesControllerTest < ActionDispatch::IntegrationTest
  VERIFIED = { verification_status: "verified", verified_by: "agent:verify" }.freeze
  NRC_LINE = "10/14/2026 12:00:00 AM|Palisades|0".freeze

  setup do
    sign_in_as users(:admin)
    @file = Source.create!(url: "https://www.nrc.gov/status-#{SecureRandom.hex(3)}.txt", source_kind: "nrc_power_status", fetched_at: Time.current,
      content_text: "ReportDt|Unit|Power\n10/13/2026 12:00:00 AM|Palisades|0\n#{NRC_LINE}\n")
    @site = Facility.create!(name: "Palisades", facility_type: "power_reactor", status: "operating", **VERIFIED)
    @unit = Facility.create!(name: "Palisades", parent: @site, nrc_docket: "05000255", status: "operating", **VERIFIED)
  end

  def preview(**params) = get admin_facility_status_path(id: @site.id), params: { status: "not_operating", unit_ids: [ @unit.id ], **params }
  def confirm(**params) = patch admin_facility_status_path(id: @site.id), params: { status: "not_operating", evidence: "nrc", nrc_quote: NRC_LINE, unit_ids: [ @unit.id ], **params }

  # Makes the next write collide with another writer's lock, as the database
  # would stop one of two transactions waiting on each other.
  module Collide
    mattr_accessor :left, default: 0

    def write(*, **)
      return super unless Collide.left.positive?

      Collide.left -= 1
      raise ActiveRecord::Deadlocked, "deadlock detected"
    end
  end
  Directory::FactWriter.singleton_class.prepend(Collide)

  test "the Record and a unit's fact page offer Change status; Edit no longer changes it" do
    get admin_record_path(type: "Facility", id: @site.id)
    assert_select "a.nd-btn[href=?]", admin_facility_status_path(id: @site.id), "Change status"
    get admin_fact_path(type: "Facility", id: @unit.id)
    assert_select "a.nd-btn[href=?]", admin_facility_status_path(id: @unit.id, page: "fact"), "Change status"
    get admin_record_edit_path(type: "Facility", id: @site.id)
    assert_select "input[name='values[status]']", false
  end

  test "the form offers NRC's newest line for the plant, and the site's units, ticked" do
    get admin_facility_status_path(id: @site.id)

    assert_response :success
    assert_select "h1", "Change status"
    assert_select "input[name=evidence][value=nrc][checked]"
    assert_select "label", /#{Regexp.escape(NRC_LINE)}/
    assert_select "input[name='unit_ids[]'][value=?][checked]", @unit.id.to_s
    assert_select "button", { text: "Change status", count: 0 }, "nothing to confirm before a preview"
  end

  test "the preview says what changes and changes nothing" do
    before = Facility.published.where(parent_id: nil, status: "operating").count
    assert_no_difference(-> { VerificationEvent.count }) { preview(evidence: "nrc") }

    assert_response :success
    assert_select "#preview-heading", "What changes"
    assert_select "li", { text: "Palisades: Operating → Not operating", count: 2 }
    assert_select "p", /operating plants go from #{before} to #{before - 1}/
    assert_select "form[method=post] button", "Change status"
    assert @site.reload.operating?
  end

  test "confirming writes the status as the person, with NRC's line as evidence, for good" do
    confirm(note: "Shut since 2022")

    assert_redirected_to admin_record_path(type: "Facility", id: @site.id)
    assert_equal "Status changed to not operating for 2 records.", flash[:notice]
    [ @site, @unit ].each do |facility|
      facility.reload
      assert facility.not_operating?
      assert_equal users(:admin).actor, facility.verified_by
      assert_equal [ NRC_LINE ], facility.evidence.where(source: @file).pluck(:quote)
      event = VerificationEvent.where(subject: facility).order(:id).last
      assert_equal "NRC's 365-day power status file: #{NRC_LINE}. Shut since 2022", event.reason
    end

    result = Directory::FactWriter.write(:facility, { id: @unit.id, status: "operating" }, protect_human_verified: true)
    assert result.conflicts.present?, "a crawler's value is overruled"
    assert @unit.reload.not_operating?
  end

  test "a link and a quote become the evidence, the link saved as a source" do
    confirm(evidence: "link", url: "https://example.com/palisades", quote: "Palisades is not operating.", unit_ids: [])

    assert @site.reload.not_operating?
    assert @unit.reload.operating?, "an unticked unit is left as it was"
    assert_equal [ "Palisades is not operating." ], @site.evidence.joins(:source).where(sources: { url: "https://example.com/palisades" }).pluck(:quote)
  end

  test "a note alone can't be published: a status needs NRC's line or a link and quote" do
    get admin_facility_status_path(id: @site.id)
    assert_select "input[name=evidence][value=note]", false, "no note-only option"

    assert_no_difference(-> { VerificationEvent.count }) { confirm(evidence: "note", note: "Told by the operator on a site visit") }
    assert_response :unprocessable_content
    assert_select ".nd-alert li", "Add NRC's status line or a link and quote. A note alone can't be published."
    assert @site.reload.operating?

    preview(evidence: "note", note: "Told by the operator")
    assert_select ".nd-alert li", "Add NRC's status line or a link and quote. A note alone can't be published."
    assert_select "button", { text: "Change status", count: 0 }

    result = DataQuality::Review.set_status(ids: [ @site.id ], status: "not_operating", by: users(:admin).actor, reason: "Told by the operator")
    assert_equal "Give a source and the quote from it that states the status", result.error, "the shared code refuses it too"
    assert @site.reload.operating?
  end

  test "missing evidence is refused, and nothing changes" do
    confirm(evidence: "link", url: "", quote: "")
    assert_response :unprocessable_content
    assert_select ".nd-alert li", "Enter a link to a public source, starting with https://"
    assert_select ".nd-alert li", "Copy the sentence from the source that states the status"

    confirm(evidence: "link", url: "javascript:alert(1)", quote: "q")
    assert_response :unprocessable_content
    assert_select ".nd-alert li", "Enter a link to a public source, starting with https://"

    assert @site.reload.operating?
  end

  test "a unit from another plant can't ride along" do
    other = Facility.create!(name: "Other Plant", status: "operating", **VERIFIED)
    other_unit = Facility.create!(name: "Other 1", parent: other, status: "operating", **VERIFIED)
    confirm(unit_ids: [ @unit.id, other_unit.id ])

    assert other_unit.reload.operating?
    assert @unit.reload.not_operating?
  end

  test "the admin action and the rake task give the same result" do
    # A second Palisades, set from the console.
    site = Facility.create!(name: "Palisades", facility_type: "power_reactor", status: "operating", **VERIFIED)
    unit = Facility.create!(name: "Palisades", parent: site, status: "operating", **VERIFIED)
    confirm
    Rails.application.load_tasks unless Rake::Task.task_defined?("directory:set_status")
    ENV["BY"] = users(:admin).actor
    ENV["APPLY"] = "1"
    capture_io { Rake::Task["directory:set_status"].execute(Rake::TaskArguments.new(%i[status ids], [ "not_operating", "#{site.id} #{unit.id}" ])) }

    state = ->(facility) { facility.reload.slice(:status, :verification_status, :verified_by).merge(quotes: facility.evidence.pluck(:quote)) }
    assert_equal [ @site, @unit ].map(&state), [ site, unit ].map(&state)
    last_reason = ->(facility) { VerificationEvent.where(subject: facility).order(:id).last.reason }
    assert_equal last_reason.(@unit), last_reason.(unit)
  ensure
    ENV.delete("BY")
    ENV.delete("APPLY")
  end

  test "a removed unit isn't offered, and a removed record can't be changed (that's Put back)" do
    removed = Facility.create!(name: "Palisades 2", parent: @site, status: "operating", **VERIFIED)
    removed.unpublish!(by: "human:tosin", reason: "Test")

    get admin_facility_status_path(id: @site.id)
    assert_select "input[name='unit_ids[]'][value=?]", removed.id.to_s, false

    confirm(unit_ids: [ @unit.id, removed.id ])
    assert removed.reload.operating?
    assert removed.unpublished?, "not put back"

    @site.unpublish!(by: "human:tosin", reason: "Test")
    confirm(status: "planned")
    assert_response :unprocessable_content
    assert_select ".nd-alert li", "Palisades is taken off or rejected. Put it back first."
    assert @site.reload.unpublished?
    assert_not @site.planned?
  end

  test "a malformed unit id selects nothing" do
    confirm(unit_ids: [ "#{@unit.id}abc", "#{@unit.id}.5" ])

    assert @site.reload.not_operating?
    assert @unit.reload.operating?
  end

  test "if NRC's file changed since the preview, it asks for another preview" do
    get admin_facility_status_path(id: @site.id), params: { status: "not_operating", evidence: "nrc" }
    assert_select "input[name=nrc_quote][value=?]", NRC_LINE

    confirm(nrc_quote: "10/12/2026 12:00:00 AM|Palisades|100")
    assert_response :unprocessable_content
    assert_select ".nd-alert li", "NRC's status file changed since the preview. Preview again to see its newest line."
    assert @site.reload.operating?
  end

  test "a reactor without a site has Change status on its page" do
    lone = Facility.create!(name: "Lone Reactor", nrc_docket: "05000999", status: "operating", **VERIFIED)
    get admin_fact_path(type: "Facility", id: lone.id)
    assert_select "a.nd-btn[href=?]", admin_facility_status_path(id: lone.id, page: "fact"), "Change status"
  end

  test "the count counts a plant the change makes public" do
    planned = Facility.create!(name: "New Plant", status: "planned", verification_status: "pending")
    before = Facility.published.where(parent_id: nil, status: "operating").count

    get admin_facility_status_path(id: planned.id), params: { status: "operating", evidence: "link", url: "https://example.com/new", quote: "New Plant is operating." }
    assert_select "p", /operating plants go from #{before} to #{before + 1}/
  end

  test "a write that collides with another writer says to try again, and changes nothing" do
    Collide.left = 1
    confirm

    assert_response :unprocessable_content
    assert_select ".nd-alert li", "Someone was changing this plant just then. Try again."
    assert @site.reload.operating?
    assert @unit.reload.operating?
  ensure
    Collide.left = 0
  end

  test "Design's fixes: Preview lands on What changes, the link's hint, 44px choices, and the way back to Live" do
    live = admin_live_path(tab: "plants")
    get admin_record_path(type: "Facility", id: @site.id, back: live)
    assert_select "a.nd-btn[href=?]", admin_facility_status_path(id: @site.id, back: live), "Change status"

    get admin_facility_status_path(id: @site.id, back: live)
    assert_select "form[method=get][action=?]", admin_facility_status_path(id: @site.id, anchor: "preview-heading")
    assert_select "form[method=get] input[name=back][value=?]", live
    assert_select "label[for=url] span", "(a public page that states the status)"
    assert_select "label.nd-choice input[name=evidence]", 2
    assert_select ".nd-crumbs a[href=?]", admin_record_path(type: "Facility", id: @site.id, back: live)

    confirm(back: live)
    assert_redirected_to admin_record_path(type: "Facility", id: @site.id, back: live)

    confirm(back: "https://elsewhere.example/")
    assert_redirected_to admin_record_path(type: "Facility", id: @site.id), "only a way back inside the admin"
  end

  test "a unit opened from Live goes back to its page in Live, with Previous and Next, after Cancel or Change status" do
    live = admin_live_path(tab: "reactors")
    unit_page = admin_fact_path(type: "Facility", id: @unit.id, from: "live", back: live)

    get unit_page
    link = admin_facility_status_path(id: @unit.id, page: "fact", from: "live", back: live)
    assert_select "a.nd-btn[href=?]", link, "Change status"

    get link
    assert_select "a.nd-btn[href=?]", unit_page, "Cancel"
    assert_select "form[method=get] input[name=from][value=live]"

    patch admin_facility_status_path(id: @unit.id), params: { status: "not_operating", evidence: "nrc", nrc_quote: NRC_LINE, page: "fact", from: "live", back: live }
    assert_redirected_to unit_page
    follow_redirect!
    assert_select ".nd-crumbs a[href=?]", live, "Live"
  end

  test "a reactor without a site, opened on its fact page, goes back to it" do
    lone = Facility.create!(name: "Lone Reactor", nrc_docket: "05000999", status: "operating", **VERIFIED)
    get admin_facility_status_path(id: lone.id, page: "fact")
    assert_select "a.nd-btn[href=?]", admin_fact_path(type: "Facility", id: lone.id), "Cancel"
  end

  test "a unit's page opened on one claim comes back on that claim" do
    first = Candidate.create!(source: @file, kind: "facility", quote: "q", status: "needs_review", notes: "unsure", subject_type: "Facility", subject_id: @unit.id, payload: { "name" => "Palisades" })
    asked = Candidate.create!(source: @file, kind: "facility", quote: "q2", status: "needs_review", notes: "unsure", subject_type: "Facility", subject_id: @unit.id, payload: { "name" => "Palisades", "state" => "MI" })
    page = admin_fact_path(type: "Facility", id: @unit.id, from: "checks", back: "/admin/checks", claim: asked.id)
    assert first.id < asked.id

    get page
    link = css_select("a.nd-btn").find { |a| a.text == "Change status" }["href"]
    assert_includes link, "claim=#{asked.id}"

    get link
    assert_select "a.nd-btn[href=?]", page, "Cancel"
    patch admin_facility_status_path(id: @unit.id), params: { status: "not_operating", evidence: "nrc", nrc_quote: NRC_LINE, page: "fact", from: "checks", back: "/admin/checks", claim: asked.id }
    assert_redirected_to page
  end
end
