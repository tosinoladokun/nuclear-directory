# "Suggest a company" on Tosin's inbox (#752): what he types (a name, a
# website or any link) becomes a lead in the one lead pipeline
# (LeadFinding), found at once instead of waiting for the night.
#
#   CompanySuggestion.suggest("Kairos Power", by: "human:tosin") # => Lead, its find queued
module CompanySuggestion
  KEY = "admin:suggest".freeze
  LABEL = "Suggested in the admin".freeze
  MAX = 500
  SHOWN_FOR = 14.days

  def self.suggest(input, by:)
    text = input.to_s.squish
    return if text.blank? || text.length > MAX

    url = text if text.match?(%r{\Ahttps?://\S+\z}i)
    name = url ? (URI.parse(url).host.to_s.delete_prefix("www.").presence || text rescue text) : text
    lead = Lead.sighted!(name:, kind: "company", key: "#{KEY}:#{Lead.normalize(text)}", label: LABEL, url:) or return
    lead.update!(status: "new", note: LeadFinding::FINDING, decided_by: by, decided_at: Time.current, reason: nil,
      record_type: nil, record_id: nil, find_attempts: 0, next_find_at: nil)
    LeadFindJob.perform_later(lead.id)
    lead
  end

  # Tosin's suggestions of the last two weeks that are being found, couldn't be confirmed (yet), or turned out
  # to be listed already. A proposed one is a Create in the inbox instead.
  def self.shown
    Lead.where(kind: "company", updated_at: SHOWN_FOR.ago..).where.not(note: nil)
      .where("leads.sources @> ?", [ { "label" => LABEL } ].to_json).order(updated_at: :desc)
  end
end
