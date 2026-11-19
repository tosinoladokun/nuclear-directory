# Infra, 18 Nov 2026: Tosin's "Add a lead" line "Aalo Atomics: https://www.aalo.com/" was kept whole as the lead's
# name, so the finder searched for that string and never checked aalo.com (fixed in this PR). Lead 105 is renamed
# "Aalo Atomics", keeps its site, and is found again at once with its tries reset (PM).
#
# Pinned: only while lead 105 still has that whole line as its name; anything else is left and named.
class AaloLead < DeployData::Migration
  ID = 105
  LINE = "Aalo Atomics: https://www.aalo.com/"

  def up
    lead = Lead.find_by(id: ID) or return say("Lead #{ID} is gone")
    return say("Lead #{ID} is already #{lead.name.inspect}") unless lead.name == LINE

    normalized = Lead.normalize("Aalo Atomics")
    if (other = Lead.where(kind: lead.kind, normalized_name: normalized).where.not(id: ID).first)
      return say("Lead #{ID} left as it is: lead #{other.id} is already Aalo Atomics")
    end

    # Its site, as the box now reads it, so the finder checks aalo.com.
    sources = lead.sources.map { |source| source["key"].to_s.start_with?(CompanySuggestion::KEY) ? source.merge("url" => "https://www.aalo.com/") : source }
    lead.update!(name: "Aalo Atomics", normalized_name: normalized, sources:, status: "new", note: nil, find_attempts: 0, next_find_at: nil)
    LeadFindJob.perform_later(ID)
    say "Lead #{ID}: Aalo Atomics (aalo.com), being found again now"
  end
end
