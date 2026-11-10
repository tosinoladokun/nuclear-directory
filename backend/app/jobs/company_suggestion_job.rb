# Finds a suggested company in the background (#752): Crawl's finder
# (DataQuality::CompanySuggestion) does the finding; this writes its outcome
# onto the suggestion (CompanySuggestion).
class CompanySuggestionJob < ApplicationJob
  queue_as :data_quality

  # (input, lead_id:) => an object whose to_h has outcome, and maybe organization_id, reason, name and website.
  # nil uses Crawl's finder; tests set their own.
  class_attribute :finder, default: nil

  def perform(lead_id, input)
    lead = Lead.find_by(id: lead_id) or return
    find = finder || (->(text, lead_id:) { DataQuality::CompanySuggestion.call(text, lead_id:) } if defined?(DataQuality::CompanySuggestion))
    return CompanySuggestion.record(lead, outcome: :unconfirmed, reason: "the finder isn't switched on yet") unless find

    found = find.call(input, lead_id:).to_h.symbolize_keys
    CompanySuggestion.record(lead, **found.slice(:outcome, :organization_id, :reason, :name, :website))
  rescue StandardError => e
    CompanySuggestion.record(lead, outcome: :unconfirmed, reason: "the search stopped (#{e.class.name.demodulize})") if lead
    raise
  end
end
