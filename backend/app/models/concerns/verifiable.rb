# Shared by every fact table (organizations, facilities, their join tables
# and both relationship tables). A fact starts as pending; what's shown
# publicly is each model's .published scope (verified, and what it hangs on
# published too; a pending site shows with a published unit, #73). A human can
# take a fact down again: it becomes
# "unpublished", which records who and when and is a human decision like a
# rejection. Every change is kept in verification_events.
module Verifiable
  extend ActiveSupport::Concern

  VERIFICATION_STATUSES = %w[pending verified rejected unpublished].freeze
  # Facts in these states only change by a human's hand.
  CLOSED_STATUSES = %w[rejected unpublished].freeze

  included do
    enum :verification_status, VERIFICATION_STATUSES.index_by(&:itself), default: "pending", validate: true

    has_many :evidence, as: :subject, dependent: :destroy
    # Append-only: deleting a fact leaves its history in place.
    has_many :verification_events, as: :subject, dependent: nil

    validates :confidence, numericality: { in: 0..1 }, allow_nil: true
    # #117: a decided record carries who and when. The helpers set both;
    # direct constructors (test builders, mocks) that only set a status get
    # verified_at auto-filled below, and the validation is the safety net
    # against a bare `.create!(verification_status: "verified")`.
    with_options if: -> { !pending? } do
      validates :verified_at, presence: { message: "is required for non-pending records (#117)" }
      validates :verified_by, presence: { message: "is required for non-pending records (#117)" }
    end
    before_validation :fill_decided_at
    validate :closed_decisions_need_a_human
    # Who is making this change (not who made the last one); set by the
    # verify!/reject!/unpublish! helpers and by FactWriter.
    # A plain accessor, not an attribute, so it never makes the record dirty.
    attr_accessor :decided_by
    after_save { self.decided_by = nil }

    # Why and in what context the next verification change is made; stored on
    # its event (see Directory::FactWriter's verification: reason:/context:).
    attribute :verification_reason, :string
    attribute :verification_context
    # Attribute changes made in the same write, kept on its event.
    attribute :audited_changes
    after_save :record_verification_event, if: -> { saved_change_to_verification_status? || saved_change_to_verified_by? }
    # The public JSON snapshot (#193) is rebuilt after any fact changes.
    after_commit { DirectorySnapshot.expire! }
  end

  # by: who made the call, e.g. "human:tosin" or "agent:verifier/<model>"
  def verify!(by:, reason: nil)
    change_verification!("verified", by:, reason:)
  end

  def reject!(by:, reason: nil)
    change_verification!("rejected", by:, reason:)
  end

  # context: recorded on the audit event, e.g. { "merged_into" => { "type", "id" } }.
  def unpublish!(by:, reason: nil, context: nil)
    change_verification!("unpublished", by:, reason:, context:)
  end

  def human_verified?
    verified? && human_reviewed?
  end

  # A human verified, rejected or unpublished this fact; automated writers
  # must not undo it.
  def human_reviewed?
    !pending? && verified_by.to_s.start_with?("human:")
  end

  class_methods do
    # What public pages show: verified facts whose own records are verified
    # too, so unpublishing a company or plant hides its facts. Models with
    # parents (links, units) narrow this further.
    def published = verified
  end

  # Rejected or unpublished: automated writers may not change it at all.
  def closed? = CLOSED_STATUSES.include?(verification_status)

  # Writes one audit event for the current verification, with any reason,
  # context and attribute changes set for this write. Used by the callback
  # below and by FactWriter for a human edit that changes values but not the
  # status.
  def log_verification_event(from_status:, by: verified_by)
    verification_events.create!(from_status:, to_status: verification_status, by:, reason: verification_reason,
      context: verification_context || {}, changed_values: audited_changes || {})
    self.verification_reason = nil
    self.verification_context = nil
    self.audited_changes = nil
  end

  # Called whenever this fact's evidence changes. The rule itself lives in
  # Evidence.combined_confidence.
  def recompute_confidence!
    update_column(:confidence, Evidence.combined_confidence(evidence.includes(:source), human_verified: human_verified?))
  end

  private
    # A record saved as non-pending without a timestamp (direct constructors
    # in tests and mocks) gets one now, so its audit event and review notes
    # always have a date. The helpers set it to Time.current explicitly.
    def fill_decided_at
      self.verified_at ||= Time.current unless pending?
    end

    # Locked, so two decisions at once are recorded in the order they happen.
    # The same decision again changes nothing, not even verified_at, so the
    # date shown always matches the audit trail.
    def change_verification!(status, by:, reason:, context: nil)
      with_lock do
        next if verification_status == status && verified_by == by

        self.verification_reason = reason
        self.verification_context = context if context
        self.decided_by = by
        update!(verification_status: status, verified_at: Time.current, verified_by: by)
        recompute_confidence!
      rescue ActiveRecord::RecordInvalid
        # A refused decision leaves the fact as it was, in memory too.
        restore_attributes(%w[verification_status verified_at verified_by])
        self.decided_by = nil
        raise
      end
    end

    # Only a human unpublishes, and only a human changes a decision once it's
    # closed (rejected or unpublished). Rejecting is open to the pipeline, which
    # retires its own proposals.
    def closed_decisions_need_a_human
      return unless will_save_change_to_verification_status? || will_save_change_to_verified_by? || will_save_change_to_verified_at?
      # A change to an existing fact's decision must say who makes it (the
      # helpers and FactWriter do), so its audit event is never attributed to
      # whoever decided last. A new fact may start in any state.
      if persisted? && decided_by.blank?
        return errors.add(:verification_status, "needs who decided: use verify!, reject!, unpublish! or FactWriter")
      end
      # The actor of this change, never the stored reviewer.
      return if decided_by.to_s.start_with?("human:")

      from = verification_status_in_database
      if unpublished?
        errors.add(:verification_status, "can only be set to unpublished by a human")
      elsif CLOSED_STATUSES.include?(from)
        errors.add(:verification_status, "was #{from}; only a human can change it")
      end
    end

    def record_verification_event
      from = verification_status_before_last_save
      return if from.nil? && pending? # a new fact starting out pending isn't a decision

      log_verification_event(from_status: from)
    end
end
