# Nightly, before the daily crawl's match (#572): bring leads up to date,
# then turn the ones an official source names into proposals.
class LeadProposalsJob < ApplicationJob
  queue_as :default

  def perform
    LeadSync.run
    LeadProposals.run
  end
end
