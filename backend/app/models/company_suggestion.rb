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

  # What he typed, read as a prompt (PM, 18 Nov): each company it names becomes a lead, with its site and a hint for
  # the finder. Returns the leads made, or nil when none could be (empty, too long, nothing named).
  def self.suggest_lines(text, by:, reader: LeadReader.new)
    lines = text.to_s.lines.map(&:squish).compact_blank
    return if lines.empty? || lines.size > MAX_LINES || lines.any? { |line| line.length > MAX }

    reader.call(text).filter_map { |item| suggest_item(item, by:) }.presence
  end

  # One company as the reader understood it.
  def self.suggest_item(item, by:)
    name = item.name.to_s.squish
    return if name.blank?

    lead = Lead.sighted!(name:, kind: "company", key: "#{KEY}:#{Lead.normalize(name)}", label: LABEL, url: item.website, hint: item.hint) or return
    queue(lead, name:, by:)
  end
  SHOWN_FOR = 14.days

  def self.suggest(input, by:)
    text = input.to_s.squish
    return if text.blank? || text.length > MAX

    url = text[%r{https?://\S+}i]
    # "Name: link", "Name - link" or "Name link" (Infra, 18 Nov: Aalo): the words name it, the link is its site.
    named = url && text.sub(url, "").squish.gsub(/\A[\s:,–—-]+|[\s:,–—-]+\z/, "").squish.presence
    # A link alone is named by its site and path, so two LinkedIn pages or two articles are two leads.
    name = named || (url ? (link_name(url) || text) : text)
    lead = Lead.sighted!(name:, kind: "company", key: "#{KEY}:#{Lead.normalize(text)}", label: LABEL, url:) or return
    queue(lead, name:, by:)
  end

  # wait: when to find it; a data step passes DeployData::Migration::AFTER_DEPLOY_WAIT, so the find runs on the
  # release being deployed, not the old one (#1018). A delayed lead waits as "researching" until then
  # (next_find_at), so neither a nightly batch nor an older queued job finds it first (LeadFinding.due; Copilot).
  def self.queue(lead, name:, by:, wait: nil)
    # The same line again while it's being found: one find is enough (Infra). By when it was queued (decided_at), not
    # updated_at, which the sighting itself moves when the date changes.
    return lead if lead.note == LeadFinding::FINDING && lead.status.in?(%w[new researching]) && lead.decided_at.to_i > 5.minutes.ago.to_i

    # His words name it, even a lead first seen in a site search (PM: "cameco").
    lead.update!(name:, status: wait ? "researching" : "new", note: LeadFinding::FINDING, decided_by: by, decided_at: Time.current,
      reason: nil, record_type: nil, record_id: nil, find_attempts: 0, next_find_at: (wait.from_now if wait))
    (wait ? LeadFindJob.set(wait:) : LeadFindJob).perform_later(lead.id)
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
