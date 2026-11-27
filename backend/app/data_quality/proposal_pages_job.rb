# Stores the pages Data Quality's new proposals cite (DataQuality::ProposalPages),
# then matches and verifies each source kind those proposals touched, so the
# verifier never checks a claim before its page is stored.
class DataQuality::ProposalPagesJob < ApplicationJob
  queue_as :data_quality

  def perform(source_ids, source_kinds)
    DataQuality::ProposalPages.store(source_ids)
  ensure
    Array(source_kinds).each { |kind| DataQuality::RunJob.perform_later(kind, only: %w[match verify]) }
  end
end
