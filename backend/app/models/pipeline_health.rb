# Whether the lead-to-Create pipeline runs alone (#811, Tosin 19 Nov: "this should work autonomously, except when I
# create on my Today"): per-stage counts, and the problems a person must hear about. Thresholds are Data Quality's.
#
#   health = PipelineHealth.new
#   health.counts   # => { "leads_new" => 12, …, "pending_without_role" => 3, … }
#   health.problems # => [ "3 pending companies have had no role for over a day", … ]
class PipelineHealth
  ZONE = "America/Los_Angeles"
  # Data Quality's thresholds (#811), in one place.
  ROLELESS_AFTER = 24.hours
  NO_CREATES_WEEKDAYS = 2
  PENDING_WAITING = 5
  STALE_AFTER = 26.hours
  UNCONFIRMED_SHARE = 0.5

  def initialize(now: Time.current)
    @now = now
  end

  def counts
    @counts ||= begin
      leads = Lead.where(kind: "company").group(:status).count
      pending = Organization.where(verification_status: "pending")
      {
        "leads_new" => leads.fetch("new", 0), "leads_researching" => leads.fetch("researching", 0),
        "leads_added" => leads.fetch("added", 0), "leads_ignored" => leads.fetch("ignored", 0),
        "pending_companies" => pending.count,
        "pending_without_role" => pending.where.not(id: OrganizationRole.select(:organization_id)).count,
        "pending_without_website" => pending.where(website: [ nil, "" ]).count,
        "pending_without_description" => pending.where(description: [ nil, "" ]).count,
        "pending_without_hq" => pending.where(hq_city: [ nil, "" ]).count,
        "creates_shown" => creates_shown,
        "finds_last_day" => finds.count,
        "finds_unconfirmed_last_day" => finds.where("note LIKE ?", "#{LeadFinding::UNCONFIRMED}%").count,
        "last_crawl_at" => CrawlRun.where(stage: "crawl").maximum(:started_at)&.iso8601,
        "last_find_at" => last_find&.iso8601,
        "data_deploy" => last_deploy&.status,
        "posts_unknown" => SocialPost.where(status: "unknown").count
      }
    end
  end

  def problems
    @problems ||= [
      roleless,
      no_creates,
      ("the last data deploy failed: #{last_deploy.error.to_s.truncate(200)}" if last_deploy&.status == "failed"),
      stale("the nightly crawl", CrawlRun.where(stage: "crawl").maximum(:started_at)),
      stale("the lead finder", last_find, only_if: counts["leads_new"].positive?),
      ("#{counts['posts_unknown']} social posts may have gone out (check the account)" if counts["posts_unknown"].positive?),
      unconfirmed
    ].compact
  end

  # Today's row, kept (one a day), for the history and the "2 weekdays" rule.
  def record!
    row = PipelineHealthSnapshot.find_or_initialize_by(on: @now.in_time_zone(ZONE).to_date)
    row.update!(counts:, problems:)
    row
  end

  private
    # A new company's Create shown today is a pending company with an open claim that proposed it.
    def creates_shown
      Candidate.where(status: %w[new matched needs_review], proposed_subject: true, kind: "organization", subject_type: "Organization").distinct.count(:subject_id)
    end

    def finds = Lead.where(kind: "company", updated_at: (@now - 1.day)..).where.not(status: "new").where.not(decided_by: nil)
    def last_find = Lead.where(kind: "company").where.not(status: %w[new triage]).maximum(:updated_at)
    def last_deploy = @last_deploy ||= DataDeploy.order(:id).last

    def roleless
      old = Organization.where(verification_status: "pending", created_at: ..(@now - ROLELESS_AFTER))
        .where.not(id: OrganizationRole.select(:organization_id)).count
      "#{old} pending companies have had no role for over a day" if old.positive?
    end

    def no_creates
      return unless counts["pending_companies"] > PENDING_WAITING

      days = PipelineHealthSnapshot.where(on: ...@now.in_time_zone(ZONE).to_date).order(on: :desc)
        .select { |row| row.on.on_weekday? }.first(NO_CREATES_WEEKDAYS)
      return unless days.size == NO_CREATES_WEEKDAYS && days.all? { |row| row.counts["creates_shown"].to_i.zero? } && counts["creates_shown"].zero?

      "no Creates in Today for #{NO_CREATES_WEEKDAYS} weekdays while #{counts['pending_companies']} companies are pending"
    end

    def stale(what, at, only_if: true)
      return unless only_if
      return "#{what} has never run" if at.nil?

      "#{what} hasn't run since #{at.in_time_zone(ZONE).strftime('%-d %b %H:%M')} PT" if at < @now - STALE_AFTER
    end

    def unconfirmed
      total, failed = counts.values_at("finds_last_day", "finds_unconfirmed_last_day")
      "#{failed} of #{total} finds in the last day couldn't confirm the company" if total >= 4 && failed > total * UNCONFIRMED_SHARE
    end
end
