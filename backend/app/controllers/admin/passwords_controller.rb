# Change your password (#783): the current one, then the new one twice. Every other
# session is signed out, so a lost laptop or an old browser loses access.
class Admin::PasswordsController < Admin::BaseController
  # Per account, so a stolen session can't guess the current password past the sign-in throttle (Copilot).
  rate_limit to: 5, within: 15.minutes, only: :update, by: -> { Current.user.id }, name: "change-password",
    store: SessionsController::RATE_LIMIT_STORE,
    with: -> { redirect_to edit_admin_password_path, alert: "Too many attempts. Try again in a few minutes." }

  def edit
  end

  def update
    user = Current.user
    unless user.authenticate(params[:current_password].to_s)
      return redirect_to(edit_admin_password_path, alert: "That isn't your current password.")
    end

    if params[:password].present? && user.update(params.permit(:password, :password_confirmation))
      user.sessions.where.not(id: Current.session.id).destroy_all
      redirect_to edit_admin_password_path, notice: "Password changed. You're signed out everywhere else."
    else
      redirect_to edit_admin_password_path, alert: user.errors.full_messages.to_sentence.presence || "Type a new password."
    end
  end
end
