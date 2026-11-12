# "Add a lead" on Tosin's inbox (#752, PM's wording 10 Nov): what he types (a
# company name, a website or any link) becomes a lead in the one lead
# pipeline (LeadFinding), found at once instead of waiting for the night.
#
#   CompanySuggestion.suggest("Kairos Power", by: "human:tosin") # => Lead, its find queued
module CompanySuggestion
  KEY = "admin:suggest".freeze
  LABEL = "Added in the admin".freeze
  MAX = 500
  # Several at once, one per line (PM, 10 Nov).
  MAX_LINES = 50

  # Each non-blank line is a lead; returns the leads made, or nil when none could be (empty, too long, too many).
  def self.suggest_lines(text, by:)
    lines = text.to_s.lines.map(&:squish).compact_blank.uniq
    return if lines.empty? || lines.size > MAX_LINES || lines.any? { |line| line.length > MAX }

    lines.filter_map { |line| suggest(line, by:) }.presence
  end
  SHOWN_FOR = 14.days

  def self.suggest(input, by:)
    text = input.to_s.squish
    return if text.blank? || text.length > MAX

    url = text if text.match?(%r{\Ahttps?://\S+\z}i)
    # A link is named by its site and path, so two LinkedIn pages or two articles are two leads.
    name = url ? (link_name(url) || text) : text
    lead = Lead.sighted!(name:, kind: "company", key: "#{KEY}:#{Lead.normalize(text)}", label: LABEL, url:) or return
    # The same line again while it's being found: one find is enough (Infra).
    return lead if lead.note == LeadFinding::FINDING && lead.status.in?(%w[new researching]) && lead.updated_at > 5.minutes.ago

    lead.update!(status: "new", note: LeadFinding::FINDING, decided_by: by, decided_at: Time.current, reason: nil,
      record_type: nil, record_id: nil, find_attempts: 0, next_find_at: nil)
    LeadFindJob.perform_later(lead.id)
    lead
  end

  def self.link_name(url)
    uri = URI.parse(url)
    "#{uri.host.to_s.delete_prefix('www.')}#{uri.path.to_s.chomp('/')}".presence
  rescue URI::InvalidURIError
    nil
  end

  # Tosin's leads added in the last two weeks (by when he added them, not when a source last mentioned them),
  # newest first, each with its state (LeadFinding.state).
  def self.shown(today: Date.current)
    added = Arel.sql(<<~SQL.squish)
      EXISTS (SELECT 1 FROM jsonb_array_elements(leads.sources) s
        WHERE s->>'label' = #{Lead.connection.quote(LABEL)} AND (s->>'last')::date >= #{Lead.connection.quote((today - SHOWN_FOR).iso8601)})
    SQL
    Lead.where(kind: "company").where(added).includes(:candidate).order(updated_at: :desc)
  end
end
