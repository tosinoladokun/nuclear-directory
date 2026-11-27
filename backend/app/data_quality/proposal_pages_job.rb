# Stores the pages Data Quality's new proposals cite (DataQuality::ProposalPages),
# then matches and verifies each source kind those proposals touched, so the
# verifier never checks a claim before its page is stored.
#
# It writes sources, so it holds the locks a web_page pipeline run holds:
# the data write lock shared (#301), then the web_page run's own lock, so a
# page is never refreshed while verify reads it (Copilot). During a deploy's
# data steps, or a web_page run, it waits and tries again, and only queues
# verify once storing has been tried. Out of tries, it queues verify anyway,
# and the claims go to review as they did before #934.
class DataQuality::ProposalPagesJob < ApplicationJob
  queue_as :data_quality
  retry_on DataQuality::WriteLock::Busy, DataQuality::Pipeline::AlreadyRunning, wait: 5.minutes, attempts: 12 do |job, _error|
    job.verify_next
  end

  def perform(source_ids, source_kinds)
    begin
      DataQuality::WriteLock.shared do
        DataQuality::Pipeline.with_lock("web_page") { DataQuality::ProposalPages.store(source_ids) }
      end
    rescue DataQuality::WriteLock::Busy, DataQuality::Pipeline::AlreadyRunning
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
