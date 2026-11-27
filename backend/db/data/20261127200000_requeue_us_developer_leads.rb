# Data Quality, 27 Nov 2026 (#987): US reactor developers from the #805 pass that the lead finder dropped: wrong
# "not US" verdicts, a missed quote, and website-only leads it never named. With #987's finder they're found again:
# each stuck lead is reset the way Tosin's suggestion resets one (CompanySuggestion.queue: tries back to 0, found again
# now), the website-only ones with the company's own name, and Scaled Atomics (never a lead) is added. Tosin approved
# ("yes, fix the finder", via PM). Leads 119 (MobileNuclear) and 128 (ThorCon) are left to run out: neither is a current
# US company. NuCube's own GlobeNewswire release (its "About NuCube Energy") is added to its lead, for its US status.
#
# Pinned on the lead ids DQ listed. A lead already added or ignored was decided by a person: left and said. Each lead
# reset here gets a "dq:987" sighting, so a rerun leaves it alone.
class RequeueUsDeveloperLeads < DeployData::Migration
  BY = "human:tosin"
  KEY = "dq:987".freeze
  LABEL = "Data Quality (#987)".freeze
  LEAD_IDS = [ 92, 110, 112, 114, 116, 124, 125, 127 ].freeze
  # The company's own name for a website-only lead, by its site's domain.
  NAMES = { "deepfission.com" => "Deep Fission", "nuclearisenergy.com" => "Nuclearis Energy", "nucube.energy" => "NuCube Energy",
    "terrestrialusa.com" => "Terrestrial Energy", "terrestrialenergy.com" => "Terrestrial Energy", "hadronenergy.com" => "Hadron Energy",
    "fanuclear.com" => "First American Nuclear" }.freeze
  RELEASES = { "nucube.energy" => "https://www.globenewswire.com/news-release/2026/06/25/3317422/0/en/nucube-energy-to-become-a-publicly-listed-company-through-business-combination-with-launch-two-acquisition-corp.html" }.freeze
  SCALED_ATOMICS = [ "Scaled Atomics", "https://www.scaledatomics.com" ].freeze

  def up
    LEAD_IDS.each { |id| requeue(id) }
    add_scaled_atomics
  end

  private
    def requeue(id)
      lead = Lead.find_by(id:)
      return say("Lead #{id} is gone; nothing to do") unless lead
      return say("Lead #{id} (#{lead.name}) is a #{lead.kind} lead, not a company; left as it is") unless lead.kind == "company"
      return say("Lead #{id} (#{lead.name}) was already queued again for #987; left as it is") if sighted?(lead)
      return say("Lead #{id} (#{lead.name}) is #{lead.status} now (a person decided it); left as it is") unless lead.status.in?(%w[triage new researching])

      domain = NAMES.keys.find { |host| ([ lead.name ] + lead.sources.map { |source| source["url"].to_s }).any? { |text| text.downcase.include?(host) } }
      name = NAMES.fetch(domain, lead.name)
      tries = lead.find_attempts
      note(lead, url: RELEASES[domain])
      CompanySuggestion.queue(lead, name:, by: BY)
      say "Lead #{id} queued again as #{name.inspect}#{' with its own release' if RELEASES[domain]} (had used #{tries} of its tries)"
    end

    def add_scaled_atomics
      name, url = SCALED_ATOMICS
      existing = Lead.find_by(kind: "company", normalized_name: Lead.normalize(name))
      return say("#{name} was already added for #987; left as it is") if existing && sighted?(existing)
      return say("#{name} is #{existing.status} already (lead #{existing.id}); left as it is") if existing && !existing.status.in?(%w[triage new researching])

      lead = Lead.sighted!(name:, kind: "company", key: KEY, label: LABEL, url:)
      CompanySuggestion.queue(lead, name:, by: BY)
      say "Added #{name} (#{url}) as lead #{lead.id}, queued to be found"
    end

    def sighted?(lead) = lead.sources.any? { |source| source["key"] == KEY }

    # The re-queue noted on the lead (and the release it reads), so it shows where it came from and a rerun skips it.
    def note(lead, url:)
      today = Date.current
      entry = { "key" => KEY, "label" => LABEL, "url" => url, "times" => 1, "first" => today.to_s, "last" => today.to_s }.compact
      lead.update!(sources: lead.sources + [ entry ], seen_count: lead.seen_count + 1, last_seen_on: [ lead.last_seen_on, today ].compact.max)
    end
end
