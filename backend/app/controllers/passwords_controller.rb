# Forgot password (#783): a one-time link by email, good for 15 minutes (Rails' password_reset_token, which
# stops working once the password changes). The same reply whether or not the address has an account.
class PasswordsController < ApplicationController
  include Authentication
  allow_unauthenticated_access
  RATE_LIMIT_STORE = SessionsController::RATE_LIMIT_STORE
  rate_limit to: 5, within: 15.minutes, only: :create, store: RATE_LIMIT_STORE,
    with: -> { redirect_to new_password_path, alert: "Too many attempts. Try again in a few minutes." }
  rate_limit to: 10, within: 15.minutes, only: :update, store: RATE_LIMIT_STORE,
    with: -> { redirect_to new_password_path, alert: "Too many attempts. Try again in a few minutes." }
  before_action :set_user_by_token, only: %i[edit update]
  layout "admin"

  def new
  end

  def create
    if (user = User.find_by(email_address: params[:email_address].to_s.strip.downcase))
      PasswordsMailer.reset(user).deliver_later
    end
    redirect_to new_session_path, notice: "If that address has an account, a link to reset its password is on its way. It works for 15 minutes."
  end

  def edit
  end

  def update
    if params[:password].present? && @user.update(params.permit(:password, :password_confirmation))
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password changed. Sign in with the new one."
    else
      redirect_to edit_password_path(params[:token]), alert: @user.errors.full_messages.to_sentence.presence || "Type a new password."
    end
  end

  private
    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: "That link has expired or was already used. Ask for a new one."
    end
end
