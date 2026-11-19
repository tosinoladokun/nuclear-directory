require "test_helper"

class Autopilot::AlertTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    Autopilot::Alert.store = ActiveSupport::Cache::MemoryStore.new
    @was_key = ENV["RESEND_API_KEY"]
    ENV["RESEND_API_KEY"] = "re_test"
  end

  teardown do
    Autopilot::Alert.store = nil
    @was_key ? ENV["RESEND_API_KEY"] = @was_key : ENV.delete("RESEND_API_KEY")
  end

  test "raising an alert emails the team inbox once; raising it again while open does nothing" do
    assert_enqueued_emails 1 do
      assert_equal :sent, Autopilot::Alert.raise!("pending-without-role", title: "No role for 24 h", body: "7 companies")
    end
    assert_no_enqueued_emails do
      assert_equal :already, Autopilot::Alert.raise!("pending-without-role", title: "No role for 24 h", body: "7 companies")
    end
  end

  test "resolving says it's back, only when the alert was open" do
    assert_no_enqueued_emails { assert_nil Autopilot::Alert.resolve!("pending-without-role") }
    Autopilot::Alert.raise!("pending-without-role", title: "No role", body: "7")
    assert_enqueued_emails(1) { assert_equal :resolved, Autopilot::Alert.resolve!("pending-without-role", note: "0 left") }
    assert_equal :sent, Autopilot::Alert.raise!("pending-without-role", title: "No role", body: "3"), "it can be raised again after"
  end

  test "the email goes to the team inbox with a plain subject and the alert's text" do
    perform_enqueued_jobs { Autopilot::Alert.raise!("crawl-missed", title: "The nightly crawl didn't run", body: "Last run 2 days ago.") }
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "hello@nuclear-directory.org" ], mail.to
    assert_equal "[autopilot] The nightly crawl didn't run", mail.subject
    assert_includes mail.body.to_s, "Last run 2 days ago."
    assert_includes mail.body.to_s, "crawl-missed"
  end

  test "without Resend's key it only logs, and never raises" do
    ENV.delete("RESEND_API_KEY")
    assert_no_enqueued_emails { assert_equal :sent, Autopilot::Alert.raise!("x", title: "t", body: "b") }
  end

  test "a failing mail never stops the caller" do
    original = AutopilotMailer.method(:notify)
    AutopilotMailer.define_singleton_method(:notify) { |**| raise "smtp down" }
    assert_equal :failed, Autopilot::Alert.raise!("y", title: "t", body: "b")
  ensure
    AutopilotMailer.define_singleton_method(:notify, original)
  end
end
