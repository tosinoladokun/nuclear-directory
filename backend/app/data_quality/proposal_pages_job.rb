# Stores the pages Data Quality's new proposals cite (DataQuality::ProposalPages),
# then matches and verifies each source kind those proposals touched, so the
# verifier never checks a claim before its page is stored.
#
# It writes sources, so it holds the data write lock shared, as a pipeline
# run does (#301): during a deploy's data steps it waits and tries again,
# and only queues verify once storing has been tried (Copilot). Out of
# tries, it queues verify anyway, and the claims go to review as they did
# before #934.
class DataQuality::ProposalPagesJob < ApplicationJob
  queue_as :data_quality
  retry_on DataQuality::WriteLock::Busy, wait: 5.minutes, attempts: 12 do |job, _error|
    job.verify_next
  end

  def perform(source_ids, source_kinds)
    begin
      DataQuality::WriteLock.shared { DataQuality::ProposalPages.store(source_ids) }
    rescue DataQuality::WriteLock::Busy
      raise
    rescue StandardError
      verify_next
      raise
    end
    verify_next
  end

  def verify_next
    source_kinds = arguments.second
    Array(source_kinds).each { |kind| DataQuality::RunJob.perform_later(kind, only: %w[match verify]) }
  end
end
