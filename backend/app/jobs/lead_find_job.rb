# The lead pipeline's runner (#752): Crawl's finder (DataQuality::LeadFinder)
# finds, checks and fills a lead; this keeps its state (LeadFinding). Nightly
# it takes up to PER_NIGHT due leads; "Suggest a company" runs one at once.
class LeadFindJob < ApplicationJob
  queue_as :data_quality
  limits_concurrency to: 1, key: "lead_find", duration: 2.hours if respond_to?(:limits_concurrency)

  # (lead) => an object whose to_h has outcome, and maybe organization_id, reason, name and website.
  # nil uses Crawl's finder; tests set their own.
  class_attribute :finder, default: nil

  def perform(lead_id = nil)
    leads = lead_id ? Lead.where(id: lead_id).to_a : LeadFinding.due.limit(LeadFinding::PER_NIGHT).to_a
    leads.each { |lead| find(lead) }
  end

  private

  def find(lead)
    finder = self.finder || (->(l) { DataQuality::LeadFinder.call(l) } if defined?(DataQuality::LeadFinder))
    # Before Crawl's finder ships, a lead waits untouched (no tries used up).
    return lead.update!(note: "Waiting for the finder") unless finder

    LeadFinding.start(lead)
    found = finder.call(lead).to_h.symbolize_keys
    LeadFinding.record(lead, **found.slice(:outcome, :organization_id, :reason, :name, :website))
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { lead_id: lead.id })
    LeadFinding.record(lead, outcome: :unconfirmed, reason: "the search stopped (#{e.class.name.demodulize})")
  end
end
