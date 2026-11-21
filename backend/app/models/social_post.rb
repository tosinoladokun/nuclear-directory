# One post the social agent (#769) drafted for a platform: posted (with its permalink), drafted (drafts mode),
# blocked by a check (with why) or failed to send (with the error). Every one is kept as the log.
class SocialPost < ApplicationRecord
  # sending: written before the API call; unknown: the call timed out or the platform errored, so it may have
  # gone out: a person checks, it's never sent again (Infra).
  # queued: handed to the publisher, going out at posted_at; cancelled: taken back by the switch before then.
  STATUSES = %w[drafted sending queued posted unknown cancelled blocked failed].freeze
  SENT = %w[sending queued posted unknown].freeze
  # A post's subject: a news item (a deal or fact) or a newly added company.
  SUBJECT_TYPES = %w[NewsItem Organization Relationship].freeze
  # No fact or company again within this, on any platform (the cross-platform cooldown).
  COOLDOWN = 14.days

  # What a reviewer's verdict quotes, so it is checkable that the text hasn't changed since (DQ, #880).
  def text_hash = Digest::SHA256.hexdigest(text.to_s).first(12)

  # A post Tosin made by hand and recorded in Admin > Posts (#877): the agent's checks never ran on it. Its reason says so, and the
  # DQ API reports it as manually recorded, not as having passed them.
  BY_HAND = "posted by hand".freeze
  def by_hand? = reason == BY_HAND

  # A draft the graders approved and handed over through POST /api/social/approved_drafts (#896): the hash they signed is the control, so the
  # send-time content recheck doesn't run on it (every send guard still does).
  GRADED = "approved by graders:".freeze
  # Graders' approval is its own fact (approved_sha256), not the mutable outcome reason: a Buffer timeout or a taken-back queued post rewrites the
  # reason, and the row must still be known as graders-approved (the DQ API, the send path).
  def graded? = approved_sha256.present?

  # The posts claimed for sending on a Los Angeles day / in a month / the last 30 days, by the day they were SENT (sent_on, set when claimed), falling
  # back to created_at for older rows: a draft created Friday and sent Monday counts on Monday, and a November draft sent in December counts in
  # December's caps (Copilot).
  scope :on_day, ->(day) { where("sent_on = :day OR (sent_on IS NULL AND created_at BETWEEN :from AND :to)", day: day.to_date, from: day.beginning_of_day, to: day.end_of_day) }
  scope :in_month, ->(time) { where("sent_on BETWEEN :s AND :e OR (sent_on IS NULL AND created_at BETWEEN :cs AND :ce)", s: time.beginning_of_month.to_date, e: time.end_of_month.to_date, cs: time.beginning_of_month, ce: time.end_of_month) }
  scope :since, ->(time) { where("COALESCE(sent_on::timestamp, created_at) >= ?", time) }

  belongs_to :subject, polymorphic: true
  validates :platform, inclusion: { in: SocialChannel::PLATFORMS }
  validates :status, inclusion: { in: STATUSES }
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }

  # Posts that count as used: sent, or drafted in drafts mode (so a trial run behaves as the real one).
  # Used: sent, queued, drafted, or failed after the call started (it may have gone out; Infra, DQ).
  # A graders-approved row waiting for its day (drafted with a send_on) hasn't used anything yet: it must not hold today's slot or a cooldown.
  scope :waiting, -> { where(status: "drafted").where.not(send_on: nil) }
  scope :not_waiting, -> { where.not(id: waiting.select(:id)) }
  scope :used, -> { where(status: [ *SENT, "drafted", "failed" ]).not_waiting }
end
