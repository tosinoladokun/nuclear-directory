require "test_helper"

class Autopilot::AlertTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @reports = []
    Autopilot::Alert.reporter = ->(key, title, _body) { @reports << [ key, title ] }
    @was_key = ENV["RESEND_API_KEY"]
    ENV["RESEND_API_KEY"] = "re_test"
  end

  teardown do
    Autopilot::Alert.reporter = nil
    restore_mailer
    @was_key ? ENV["RESEND_API_KEY"] = @was_key : ENV.delete("RESEND_API_KEY")
  end

  def break_mailer
    @original_notify = AutopilotMailer.method(:notify)
    AutopilotMailer.define_singleton_method(:notify) { |**| raise "smtp down" }
  end

  def restore_mailer
    AutopilotMailer.define_singleton_method(:notify, @original_notify) if @original_notify
    @original_notify = nil
  end

  test "raising an alert emails the team inbox and reports to Sentry once; raising it again while open does nothing" do
    assert_enqueued_emails(1) { assert_equal :sent, Autopilot::Alert.raise!("pending-without-role", title: "No role for 24 h", body: "7 companies") }
    assert_equal [ [ "pending-without-role", "No role for 24 h" ] ], @reports
    assert_no_enqueued_emails { assert_equal :already, Autopilot::Alert.raise!("pending-without-role", title: "No role for 24 h", body: "7 companies") }
    assert_equal 1, @reports.size
  end

  test "it reminds again after 20 hours while the problem lasts" do
    Autopilot::Alert.raise!("crawl-silent", title: "No crawl", body: "x")
    travel 21.hours do
      assert_enqueued_emails(1) { assert_equal :sent, Autopilot::Alert.raise!("crawl-silent", title: "No crawl", body: "x") }
    end
    assert_equal 2, @reports.size
  end

  test "a recovery is still said days later, not forgotten after 20 hours (Copilot)" do
    Autopilot::Alert.raise!("stuck-leads", title: "Stuck", body: "3 leads")
    travel 3.days do
      assert_enqueued_emails(1) { assert_equal :resolved, Autopilot::Alert.resolve!("stuck-leads", note: "0 left") }
    end
    assert_nil Autopilot::Alert.resolve!("stuck-leads"), "only once"
    assert_not Autopilot::Alert.open?("stuck-leads")
    assert_equal :sent, Autopilot::Alert.raise!("stuck-leads", title: "Stuck", body: "1 lead"), "it can be raised again after"
  end

  test "resolving something that was never open says nothing" do
    assert_no_enqueued_emails { assert_nil Autopilot::Alert.resolve!("never-raised") }
  end

  test "a failed email is tried again next time, without re-sending the Sentry report" do
    break_mailer
    assert_equal :sent, Autopilot::Alert.raise!("budget", title: "Budget", body: "x"), "Sentry still went out"
    assert_equal 1, @reports.size
    restore_mailer

    assert_enqueued_emails(1) { assert_equal :sent, Autopilot::Alert.raise!("budget", title: "Budget", body: "x") }
    assert_equal 1, @reports.size, "Sentry is not sent twice"
    assert_no_enqueued_emails { assert_equal :already, Autopilot::Alert.raise!("budget", title: "Budget", body: "x") }
  end

  test "a Sentry outage never stops the email (Copilot)" do
    Autopilot::Alert.reporter = ->(*) { raise "sentry down" }
    assert_enqueued_emails(1) { assert_equal :sent, Autopilot::Alert.raise!("finder-silent", title: "No finder", body: "x") }
  end

  test "a failed recovery email leaves the alert open so it is tried again" do
    Autopilot::Alert.raise!("posts-unknown", title: "Unknown post", body: "x")
    break_mailer
    assert_nil Autopilot::Alert.resolve!("posts-unknown")
    assert Autopilot::Alert.open?("posts-unknown")
    restore_mailer
    assert_enqueued_emails(1) { assert_equal :resolved, Autopilot::Alert.resolve!("posts-unknown") }
  end

  test "the email goes to the team inbox with a plain subject, the alert's text and a working health link" do
    perform_enqueued_jobs { Autopilot::Alert.raise!("crawl-missed", title: "The nightly crawl didn't run", body: "Last run 2 days ago.") }
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "hello@nuclear-directory.org" ], mail.to
    assert_equal "[autopilot] The nightly crawl didn't run", mail.subject
    assert_includes mail.body.to_s, "Last run 2 days ago."
    assert_includes mail.body.to_s, "crawl-missed"
    assert_match %r{/admin/health\b}, mail.body.to_s
  end

  test "without Resend's key it only logs, and never raises" do
    ENV.delete("RESEND_API_KEY")
    assert_no_enqueued_emails { assert_equal :sent, Autopilot::Alert.raise!("x", title: "t", body: "b") }
  end
end
