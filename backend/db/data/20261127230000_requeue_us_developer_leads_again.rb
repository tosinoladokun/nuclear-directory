# Data Quality, 27 Nov 2026 (#1015): after #987's re-queue, four US developers still weren't found, and three of the
# misses were the finder's. Terrestrial's address is only in its page's structured data, behind a canonical link;
# Deep Fission's and Hadron's nuclear sentence is on their investor pages. NuCube was still being found. Nuclearis
# (a captcha, now recorded as blocked) isn't re-queued: Tosin said no to it. With #1015's finder they're found again, reset the way Tosin's suggestion
# resets a lead (CompanySuggestion.queue). Covered by Tosin's "yes, fix the finder" for these developers (27 Nov, via PM).
#
# Pinned on the lead ids DQ listed. A lead already added or ignored was decided by a person: left and said. Each lead
# reset here gets a "dq:1015" sighting, so a rerun leaves it alone. Names were set by #987's step and stay.
class RequeueUsDeveloperLeadsAgain < DeployData::Migration
  BY = "human:tosin"
  # The names it keeps were set by #987's step.
  AFTER = %w[20261127200000].freeze
  KEY = "dq:1015".freeze
  LABEL = "Data Quality (#1015)".freeze
  # Hadron, Deep Fission, NuCube, Terrestrial. Not Nuclearis (124): Tosin said no to it, and DQ closes its lead (via PM).
  LEAD_IDS = [ 110, 112, 125, 127 ].freeze

  def up
    LEAD_IDS.each do |id|
      lead = Lead.find_by(id:)
      next say("Lead #{id} is gone; nothing to do") unless lead
      next say("Lead #{id} (#{lead.name}) is a #{lead.kind} lead, not a company; left as it is") unless lead.kind == "company"
      next say("Lead #{id} (#{lead.name}) was already queued again for #1015; left as it is") if lead.sources.any? { |source| source["key"] == KEY }
      next say("Lead #{id} (#{lead.name}) is #{lead.status} now (a person decided it); left as it is") unless lead.status.in?(%w[triage new researching])

      tries = lead.find_attempts
      today = Date.current
      entry = { "key" => KEY, "label" => LABEL, "times" => 1, "first" => today.to_s, "last" => today.to_s }
      lead.update!(sources: lead.sources + [ entry ], seen_count: lead.seen_count + 1, last_seen_on: [ lead.last_seen_on, today ].compact.max)
      CompanySuggestion.queue(lead, name: lead.name, by: BY)
      say "Lead #{id} (#{lead.name}) queued again (had used #{tries} of its tries)"
    end
  end
end
