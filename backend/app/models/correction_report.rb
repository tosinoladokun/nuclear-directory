# A correction a visitor sent about a fact or a page (#44). Stored without
# any IP address; contact is only there if they want a reply.
class CorrectionReport < ApplicationRecord
  enum :status, %w[open reviewed closed].index_by(&:itself), default: "open"

  normalizes :subject, :page_path, :contact, with: ->(value) { value.strip.presence }
  normalizes :message, with: ->(value) { value.strip }

  validates :subject, presence: true, length: { maximum: 300 }
  LOCAL_PATH = %r{\A/(?![/\\])[^\s\\]{0,299}\z}

  # A path on this site: one leading slash, no backslashes or whitespace.
  def self.local_path?(path) = path.to_s.match?(LOCAL_PATH)

  validates :page_path, presence: true, format: { with: LOCAL_PATH }
  validates :message, presence: { message: "Say what should change before sending." }, unless: -> { proposed_changes.present? }
  validates :message, length: { maximum: 5000, message: "Keep it to 5,000 characters or fewer." }

  # One form (#591): a correction, an update to a listing ("Claim or update
  # this listing"), a new company or plant, a new fact, or a source to read.
  KINDS = %w[correction listing new_record new_fact source].freeze
  RECORD_TYPES = %w[Organization Facility].freeze
  # What a visitor may propose for each kind of record; a name never changes here.
  FIELDS = { "Organization" => %w[website description hq_city hq_state founded_year legal_name],
             "Facility" => %w[city state] }.freeze
  validates :kind, inclusion: { in: KINDS }
  validates :record_type, inclusion: { in: RECORD_TYPES }, allow_nil: true
  validates :source_url, presence: { message: "Add a link to a source that shows it." }, unless: -> { kind == "correction" }
  validates :source_url, format: { with: %r{\Ahttps?://\S+\z}, message: "Enter a link starting with https://." }, length: { maximum: 2000 }, allow_nil: true
  validates :claimant_name, :claimant_role, length: { maximum: 200 }
  validates :claimant_email, length: { maximum: 200 }, format: { with: /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, message: "Enter an email like name@example.com." },
    allow_nil: true
  normalizes :source_url, :claimant_name, :claimant_role, :claimant_email, with: ->(value) { value.strip.presence }
  validate :changes_fit_the_record

  # A listing update or suggestion needs no message (the column can't be null).
  before_validation { self.message ||= "" }

  # The proposed values: [{ "field" => "hq_city", "value" => "Austin", "quote" => "…" }].
  def change_rows = Array(proposed_changes).select { |row| row.is_a?(Hash) }
  validates :contact, length: { maximum: 200, message: "Keep the email to 200 characters or fewer." },
    format: { with: /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, message: "Enter an email like name@example.com, or leave it empty." },
    allow_nil: true

  # How a closed report ended (#86's inbox): the record was changed, or not.
  RESOLUTIONS = %w[fixed dismissed].freeze
  validates :resolution, inclusion: { in: RESOLUTIONS }, allow_nil: true
  validates :decided_by, format: { with: /\Ahuman:\S+\z/ }, allow_nil: true

  # A report changed from a stale page (already closed, say) is refused.
  class InvalidTransition < StandardError; end

  # Closes an open or in-progress report as fixed or dismissed, by a human ("human:tosin").
  def close!(resolution, by:)
    transition(from: %w[open reviewed]) { update!(status: "closed", resolution:, decided_by: by, decided_at: Time.current) }
  end

  # Someone is looking at an open report (it stays in the open list).
  def start!(by:) = transition(from: %w[open]) { update!(status: "reviewed", decided_by: by) }

  def reopen! = transition(from: %w[closed]) { update!(status: "open", resolution: nil, decided_by: nil, decided_at: nil) }

  private
    def changes_fit_the_record
      return unless %w[listing new_record].include?(kind)

      errors.add(:record_type, "Say whether it's a company or a plant.") unless RECORD_TYPES.include?(record_type)
      errors.add(:record_id, "Say which listing it is.") if kind == "listing" && record_id.blank?
      allowed = FIELDS.fetch(record_type.to_s, []) + (kind == "new_record" ? %w[name] : [])
      rows = change_rows
      errors.add(:proposed_changes, "Say what should change.") if rows.empty?
      errors.add(:proposed_changes, "Give the new company or plant's name.") if kind == "new_record" && rows.none? { |row| row["field"] == "name" && row["value"].present? }
      rows.each do |row|
        errors.add(:proposed_changes, "#{row['field'].to_s.humanize} can't be changed here.") unless allowed.include?(row["field"].to_s)
        errors.add(:proposed_changes, "Give a value for #{row['field'].to_s.humanize(capitalize: false)}.") if row["value"].to_s.strip.empty?
      end
      errors.add(:proposed_changes, "Send at most 10 changes at once.") if rows.size > 10
    end
    def transition(from:)
      with_lock do
        raise InvalidTransition, "it's already #{status == 'reviewed' ? 'in progress' : status}" unless from.include?(status)

        yield
      end
    end
end
