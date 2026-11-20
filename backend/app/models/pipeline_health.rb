# Whether the lead-to-Create pipeline runs alone (#811, Tosin 19 Nov: "this should work autonomously, except when I
# create on my Today"): per-stage counts, and the problems a person must hear about. Thresholds are Data Quality's.
#
#   health = PipelineHealth.new
#   health.counts   # => { "leads_new" => 12, …, "pending_without_role" => 3, … }
#   health.problems # => [ "3 pending companies have had no role for over a day", … ]
class PipelineHealth
  ZONE = "America/Los_Angeles"
  # Data Quality's thresholds (#811, 19 Nov), in one place.
  ROLELESS_AFTER = 24.hours
  SITELESS_AFTER = 48.hours
  NO_CREATES_WEEKDAYS = 2
  PENDING_WAITING = 5
  UNCHECKED_MAX = 100
  UNCHECKED_OLDEST = 3.days
  NEW_LEAD_AFTER = 48.hours
  STALE_AFTER = 26.hours
  UNCONFIRMED_SHARE = 0.5
  BUDGET_SHARE = 0.8
  SOURCE_SILENT_AFTER = 72.hours
  # Run by their own schedules, not the daily crawl (config/recurring.yml).
  RECURRING_SOURCES = %w[wire_press lead_forwards].freeze

  def initialize(now: Time.current)
    @now = now
  end

  def counts
    @counts ||= begin
      leads = Lead.where(kind: "company").group(:status).count
      pending = real_pending
      {
        "leads_new" => leads.fetch("new", 0), "leads_researching" => leads.fetch("researching", 0),
        "leads_added" => leads.fetch("added", 0), "leads_ignored" => leads.fetch("ignored", 0),
        "pending_companies" => pending.count,
        "pending_without_role" => pending.where.not(id: sourced_role_scope).count,
        "pending_without_website" => pending.where(website: [ nil, "" ]).count,
        "pending_without_description" => pending.where(description: [ nil, "" ]).count,
        "pending_without_hq" => pending.where(hq_city: [ nil, "" ]).count,
        "creates_shown" => creates_shown,
        "finds_last_day" => finds_last_day,
        "finds_unconfirmed_last_day" => Lead.where(kind: "company", updated_at: (@now - 1.day)..).where("note LIKE ?", "#{LeadFinding::UNCONFIRMED}%").count,
        "last_crawl_at" => last_crawl&.iso8601,
        "last_find_at" => last_find&.iso8601,
        "data_deploy" => last_deploy&.status,
        "posts_unknown" => SocialPost.where(status: "unknown").count,
        "claims_unchecked" => unchecked.count,
        "leads_stuck" => stuck_leads.count,
        "budget_spent" => DataQuality::Budget.spent_this_month(now: @now).to_f.round(2),
        # Finds that reached an answer (added, or checked and couldn't confirm a site), whatever the search did:
        # a reserved search row is written before the call, so it doesn't prove Brave answered (Copilot).
        "finds_answered_last_day" => Lead.where(kind: "company", updated_at: (@now - 1.day)..)
          .where("status = 'added' OR note LIKE ?", "#{LeadFinding::UNCONFIRMED}%").count,
        # Held for the search itself only (not the pipeline lock or the day's find quota, which share BUSY; Copilot).
        "searches_held_last_day" => Lead.where(kind: "company", updated_at: (@now - 1.day)..)
          .where("note ILIKE ? OR note ILIKE ? OR note ILIKE ?", "%search limit%", "%no search today%", "%search service was busy%").count
      }
    end
  end

  def problems = checks.values.compact

  # Every check by its stable alert key (Infra's Autopilot::Alert dedupes on it): the problem, or nil when fine.
  def checks
    @checks ||= {
      "pending-without-role" => roleless,
      "pending-without-website" => siteless,
      "no-creates" => no_creates,
      "unchecked-claims" => unchecked_claims,
      "stuck-leads" => ("#{counts['leads_stuck']} leads are stuck (used their four tries, or waiting over two days)" if counts["leads_stuck"].positive?),
      "data-deploy-failed" => ("the last data deploy failed (see the deploy report)" if last_deploy&.status == "failed"),
      "crawl-silent" => stale("the nightly crawl", last_crawl),
      "finder-silent" => stale("the lead finder", last_find, only_if: LeadFinding.due(now: @now).exists?),
      "company-pages-failing" => company_pages_failing,
      "posts-unknown" => ("#{counts['posts_unknown']} social posts may have gone out (check the account)" if counts["posts_unknown"].positive?),
      "finds-unconfirmed" => unconfirmed,
      "budget" => budget,
      "social-silent" => social_silent,
      "indexnow-refused" => ("IndexNow refused the last two batches (check INDEXNOW_KEY and its key file)" if IndexNowSubmission.refused_twice?),
      "search-limit" => search_limit,
      "sources-silent" => sources_silent
    }
  end

  # Today's row, kept (one a day), for the history and the "2 weekdays" rule.
  def record!
    row = PipelineHealthSnapshot.find_or_initialize_by(on: @now.in_time_zone(ZONE).to_date)
    row.update!(counts:, problems:)
    row
  end

  private
    # The Creates Today actually shows (its own selection, roles, checks and daily limit; Copilot).
    def creates_shown = OwnerInbox.new.then { |inbox| inbox.sections["new_record"].size + inbox.records.size }

    # The nightly crawl's own sources (DailyCrawlJob), so hourly feeds can't hide it stopping (Copilot).
    def last_crawl = @last_crawl ||= CrawlRun.where(stage: "crawl", source_kind: DataQuality::DailyCrawlJob::SOURCE_KINDS).maximum(:started_at)

    # The finder's own record: each find reserves a lead_finder row (Copilot), not a lead's updated_at.
    def finder_rows = CrawlRun.where(source_kind: "lead_finder", stage: "crawl").where("stats ? 'finds'")
    def finds_last_day = finder_rows.where(started_at: (@now - 1.day)..).count
    def last_find = @last_find ||= finder_rows.maximum(:started_at)

    # A role that lets a Create show: pending or verified, with evidence (Directory::Lookup.sourced_role_ids; Copilot).
    def sourced_role_scope
      OrganizationRole.where(verification_status: %w[pending verified])
        .where(id: Evidence.where(subject_type: "OrganizationRole").select(:subject_id)).select(:organization_id)
    end
    def last_deploy = @last_deploy ||= DataDeploy.order(:id).last

    # Pending companies that aren't junk: none whose new-company claim Data Quality said no to (DQ, 19 Nov).
    def real_pending
      junk = Candidate.where(proposed_subject: true, subject_type: "Organization", dq_recommendation: "reject").select(:subject_id)
      Organization.where(verification_status: "pending").where.not(id: junk)
    end

    def roleless
      old = real_pending.where(created_at: ..(@now - ROLELESS_AFTER)).where.not(id: sourced_role_scope).count
      "#{old} pending companies have had no role for over a day" if old.positive?
    end

    def siteless
      old = real_pending.where(created_at: ..(@now - SITELESS_AFTER), website: [ nil, "" ]).count
      "#{old} pending companies have had no website for over two days" if old.positive?
    end

    # Open company claims nobody has judged yet (no Data Quality verdict).
    def unchecked = Candidate.where(kind: "organization", status: %w[new matched needs_review], dq_recommendation: nil)

    def unchecked_claims
      oldest = unchecked.minimum(:created_at)
      if counts["claims_unchecked"] > UNCHECKED_MAX || (oldest && oldest < @now - UNCHECKED_OLDEST)
        "#{counts['claims_unchecked']} company claims have no verdict yet" + (oldest ? ", the oldest since #{oldest.in_time_zone(ZONE).strftime('%-d %b')}" : "")
      end
    end

    def stuck_leads
      Lead.where(kind: "company").where(status: "researching", find_attempts: LeadFinding::TRIES..)
        .or(Lead.where(kind: "company", status: "new", created_at: ..(@now - NEW_LEAD_AFTER)))
    end

    def company_pages_failing
      last_two = CrawlRun.where(source_kind: "company_pages").order(started_at: :desc).limit(2).pluck(:status)
      "the company pages read failed twice in a row" if last_two.size == 2 && last_two.all?("failed")
    end

    # Each scheduled source must have crawled within three days (PM via Crawl).
    def sources_silent
      daily = DataQuality::DailyCrawlJob
      # NOT_SCHEDULED is a Hash of kind => why (Crawl's #822); a list works too (Infra).
      skipped = daily.const_defined?(:NOT_SCHEDULED) ? daily::NOT_SCHEDULED : []
      kinds = daily::SOURCE_KINDS + RECURRING_SOURCES - (skipped.respond_to?(:keys) ? skipped.keys : Array(skipped))
      last = CrawlRun.where(stage: "crawl", source_kind: kinds).group(:source_kind).maximum(:started_at)
      silent = kinds.select { |kind| last[kind].nil? || last[kind] < @now - SOURCE_SILENT_AFTER }
      "#{silent.size} sources haven't run in three days: #{silent.sort.join(', ')}" if silent.any?
    end

    # Brave refused every search for a day (its monthly limit or the key; Infra): leads wait instead of being found.
    # The last weekday, a platform that wasn't off wrote no post (DQ, shadow day 20 Nov): named with the run's
    # reason when it gave one (SocialAgent.stopped), so "no fresh item" reads differently from silence.
    def social_silent
      zone = Time.find_zone(SocialAgent::ZONE)
      day = @now.in_time_zone(zone).to_date.prev_day
      day = day.prev_day while day.on_weekend?
      return if SocialAgent::Rules.holiday?(day)

      range = zone.local(day.year, day.month, day.day).all_day
      quiet = SocialChannel.where.not(mode: "off").pluck(:platform).reject { |platform| SocialPost.where(platform:, created_at: range).exists? }
      return if quiet.empty?

      why = CrawlRun.where(source_kind: SocialAgent::STOPPED, started_at: range).where("stats ? 'stopped'")
        .order(:started_at).to_h { |run| [ run.stats["platform"], run.stats["stopped"] ] }
      "No social draft on #{day.strftime('%a %-d %b')}: " + quiet.sort.map { |platform| "#{platform} (#{why[platform] || 'no run recorded'})" }.join(", ")
    end

    def search_limit
      held, done = counts.values_at("searches_held_last_day", "finds_answered_last_day")
      "#{held} lead finds waited a day because the search didn't answer (its monthly limit or key)" if held.positive? && done.zero?
    end

    def budget
      cap = DataQuality::Config.from_env.monthly_budget.to_f
      "this month's model budget is #{(counts['budget_spent'] / cap * 100).round}% used" if cap.positive? && counts["budget_spent"] >= cap * BUDGET_SHARE
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
