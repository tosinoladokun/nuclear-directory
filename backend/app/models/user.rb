# An admin account (#86). Made with `bin/rails admin:create`.
class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :handle, with: ->(h) { h.strip.downcase }

  validates :handle, presence: true, uniqueness: true, format: { with: /\A[a-z][a-z0-9_-]*\z/ }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :email_address, presence: true, uniqueness: true, format: { with: /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ }

  # Sets a new password from a reset link (#783): :done, :expired (the link no longer works), or why not. The
  # token is checked again with the account's row locked, so two uses of one link can't both succeed (Copilot);
  # every session is signed out in the same transaction.
  def self.reset_password(token, attributes)
    transaction do
      user = find_by_password_reset_token(token.to_s)&.lock! or next :expired
      next :expired unless find_by_password_reset_token(token.to_s)&.id == user.id
      next "" if attributes[:password].blank?
      next user.errors.full_messages.to_sentence unless user.update(attributes)

      user.sessions.destroy_all
      :done
    end
  end

  # Who decided, in the audit trail: "human:tosin".
  def actor = "human:#{handle}"
end
