# The lead pipeline's runner (#752): Crawl's finder (DataQuality::Plugins::LeadFinder)
# finds, checks and fills a lead; this keeps its state (LeadFinding). Nightly
# it takes up to PER_NIGHT due leads; "Suggest a company" runs one at once.
class LeadFindJob < ApplicationJob
  queue_as :data_quality
  # One find at a time (the finder's search and daily quota are shared; Copilot). The nightly run only queues one job
  # per lead at a lower priority, so a lead from the admin box (priority 0) is next, never behind the whole batch
  # (PM, 18 Nov: Fluor waited).
  limits_concurrency to: 1, key: "lead_find", duration: 30.minutes if respond_to?(:limits_concurrency)
  BATCH_PRIORITY = 10

  # (lead) => an object whose to_h has outcome, and maybe candidate_id (the claim it proposed), organization_id
  # (already listed), reason, name and website.
  # nil uses Crawl's finder; tests set their own.
  class_attribute :finder, default: nil

  def perform(lead_id = nil)
    unless lead_id
      LeadFinding.due.limit(LeadFinding::PER_NIGHT).pluck(:id).each { |id| self.class.set(priority: BATCH_PRIORITY).perform_later(id) }
      return
    end

    # A queued find for one lead still has to be due: a lead found meanwhile, or ignored by a person, is left alone.
    LeadFinding.due.where(id: lead_id).each { |lead| find(lead) }
  end

  private

  def find(lead)
    finder = self.finder || (->(l) { DataQuality::Plugins::LeadFinder.call(l.id) } if defined?(DataQuality::Plugins::LeadFinder))
    # Before Crawl's finder ships, a lead waits untouched (no tries used up).
    return lead.update!(note: "Waiting for the finder") unless finder

    return lead.update!(note: LeadFinding::WAITING) unless LeadFinding.take_today

    attempt = LeadFinding.start(lead) or return
    found = finder.call(lead).to_h.symbolize_keys
    LeadFinding.record(lead, attempt:, **found.slice(:outcome, :organization_id, :candidate_id, :reason, :name, :website))
  rescue DataQuality::Pipeline::AlreadyRunning
    # Overlapping the nightly match: try again soon, without using up a try (Infra).
    LeadFinding.record(lead, attempt:, outcome: :retry) if attempt
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { lead_id: lead.id })
    LeadFinding.record(lead, attempt:, outcome: :unconfirmed, reason: "the search stopped (#{e.class.name.demodulize})") if attempt
  end
end
