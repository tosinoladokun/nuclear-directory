require "test_helper"

# #783: change your password in the admin, and a safe way back in when it's forgotten.
class PasswordsTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @user = users(:admin)
    SessionsController::RATE_LIMIT_STORE.clear
  end

  test "change password: the current one first; the new one twice; every other session signed out" do
    other = @user.sessions.create!(ip_address: "1.2.3.4", user_agent: "old laptop")
    sign_in_as @user
    get edit_admin_password_path
    assert_response :success

    patch admin_password_path, params: { current_password: "wrong", password: "a-new-long-password", password_confirmation: "a-new-long-password" }
    assert_equal "That isn't your current password.", flash[:alert]
    patch admin_password_path, params: { current_password: "correct horse battery staple", password: "short", password_confirmation: "short" }
    assert_match "too short", flash[:alert]
    patch admin_password_path, params: { current_password: "correct horse battery staple", password: "a-new-long-password", password_confirmation: "different-long-password" }
    assert_match "doesn't match", flash[:alert]
    patch admin_password_path, params: { current_password: "correct horse battery staple", password: "", password_confirmation: "" }
    assert_equal "Type a new password.", flash[:alert]

    patch admin_password_path, params: { current_password: "correct horse battery staple", password: "a-new-long-password", password_confirmation: "a-new-long-password" }
    assert_match "Password changed", flash[:notice]
    assert @user.reload.authenticate("a-new-long-password")
    assert_not Session.exists?(other.id), "the old laptop is signed out"
    get edit_admin_password_path
    assert_response :success, "this session stays signed in"
  end

  test "forgot password: the same reply either way; the link works once, for 15 minutes" do
    get new_session_path
    assert_select "a[href=?]", new_password_path

    assert_enqueued_emails(0) { post passwords_path, params: { email_address: "nobody@example.com" } }
    unknown = flash[:notice]
    assert_enqueued_emails(1) { post passwords_path, params: { email_address: "  ADMIN@example.com " } }
    assert_equal unknown, flash[:notice], "the same reply whether or not the address has an account"

    token = @user.password_reset_token
    get edit_password_path(token)
    assert_response :success
    put password_path(token), params: { password: "reset-long-password", password_confirmation: "reset-long-password" }
    assert @user.reload.authenticate("reset-long-password")
    assert_empty @user.sessions

    put password_path(token), params: { password: "again-long-password", password_confirmation: "again-long-password" }
    assert_match "expired or was already used", flash[:alert], "once only: the password changed"

    later = @user.password_reset_token
    travel 16.minutes do
      get edit_password_path(later)
      assert_match "expired", flash[:alert]
    end
  end

  test "the reset email holds the link" do
    mail = PasswordsMailer.reset(@user)
    assert_equal [ @user.email_address ], mail.to
    assert_match %r{/admin/session/password/[^/\s]+/edit}, mail.body.encoded
  end

  test "asking for links is rate-limited" do
    5.times { post passwords_path, params: { email_address: "nobody@example.com" } }
    post passwords_path, params: { email_address: "nobody@example.com" }
    assert_match "Too many attempts", flash[:alert]
  end

  test "a link is checked again under the account's lock: the second of two uses fails, and the first password stays" do
    token = @user.password_reset_token
    assert_equal :done, User.reset_password(token, { password: "first-long-password", password_confirmation: "first-long-password" })
    assert_equal :expired, User.reset_password(token, { password: "second-long-password", password_confirmation: "second-long-password" })
    assert @user.reload.authenticate("first-long-password")
  end

  test "asking for links and trying new passwords are counted apart" do
    5.times { post passwords_path, params: { email_address: "nobody@example.com" } }
    token = @user.password_reset_token
    put password_path(token), params: { password: "reset-long-password", password_confirmation: "reset-long-password" }
    assert_match "Password changed", flash[:notice]
  end

  test "changing the password allows a few tries of the current one per account" do
    sign_in_as @user
    5.times { patch admin_password_path, params: { current_password: "wrong", password: "a-new-long-password", password_confirmation: "a-new-long-password" } }
    patch admin_password_path, params: { current_password: "correct horse battery staple", password: "a-new-long-password", password_confirmation: "a-new-long-password" }
    assert_match "Too many attempts", flash[:alert]
    assert_not @user.reload.authenticate("a-new-long-password")
  end
end
