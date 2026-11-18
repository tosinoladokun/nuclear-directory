# One post the social agent (#769) drafted for a platform: posted (with its permalink), drafted (drafts mode),
# blocked by a check (with why) or failed to send (with the error). Every one is kept as the log.
class SocialPost < ApplicationRecord
  # sending: written before the API call; unknown: the call timed out or the platform errored, so it may have
  # gone out: a person checks, it's never sent again (Infra).
  STATUSES = %w[drafted sending posted unknown blocked failed].freeze
  SENT = %w[sending posted unknown].freeze
  # A post's subject: a news item (a deal or fact) or a newly added company.
  SUBJECT_TYPES = %w[NewsItem Organization].freeze
  # No fact or company again within this, on any platform (the cross-platform cooldown).
  COOLDOWN = 14.days

  belongs_to :subject, polymorphic: true
  validates :platform, inclusion: { in: SocialChannel::PLATFORMS }
  validates :status, inclusion: { in: STATUSES }
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }

  # Posts that count as used: sent, or drafted in drafts mode (so a trial run behaves as the real one).
  scope :used, -> { where(status: [ *SENT, "drafted" ]) }
end
