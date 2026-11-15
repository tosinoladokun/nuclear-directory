# The reset link for Forgot password (#783), in plain text, through Resend.
class PasswordsMailer < ApplicationMailer
  FROM = CorrectionMailer::FROM

  def reset(user)
    @user = user
    mail(from: FROM, to: user.email_address, subject: "Reset your Nuclear Directory password") do |format|
      format.text
    end
  end
end
