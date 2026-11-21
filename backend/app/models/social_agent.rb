# The social agent (#769): each weekday morning, one post per platform about fresh directory data, written,
# checked and (when the platform is live) sent. Nothing goes out unless every check passes; every attempt is
# logged as a SocialPost. Each platform has a switch in the admin (off, drafts, live).
module SocialAgent
  ZONE = "America/Los_Angeles"
  SITE = "https://nuclear-directory.org"

  # Publishers by platform, each ->(text, link) returning { id:, due_at: } (queued) or { id:, permalink: } (sent).
  # Both go through Buffer (PM, 18 Nov); swap one here to change how a platform is published.
  def self.senders = @senders ||= SocialChannel::PLATFORMS.to_h { |platform| [ platform, ->(text, link) { publisher.call(platform, text, link) } ] }
  def self.publisher = SocialAgent::Buffer.new

  # Sending is on only when SOCIAL_POSTING_ENABLED is "on" (Render dashboard; Infra): otherwise Live drafts too.
  def self.sending_enabled? = ENV["SOCIAL_POSTING_ENABLED"] == "on"
  # What one post costs us (Buffer's free plan: nothing; kept for a paid publisher) and the most a month may cost.
  def self.post_cost = BigDecimal(ENV.fetch("SOCIAL_POST_COST_USD", "0"))
  def self.monthly_cap = BigDecimal(ENV.fetch("SOCIAL_MONTHLY_CAP_USD", "10"))
  # A backstop on the number of posts per platform a month (Infra): weekdays only make about 22.
  def self.monthly_max = ENV.fetch("SOCIAL_MONTHLY_MAX", "25").to_i

  # A send whose outcome isn't known (timeout, 5xx, 429): it may have gone out, so it's never sent again.
  class Uncertain < StandardError; end

  # Its fact still published at send time: a link also needs both companies published and to be in effect (Copilot).
  def self.still_published?(subject)
    return NewsItem.published.exists?(subject.id) if subject.is_a?(NewsItem)
    return subject.verification_status == "verified" unless subject.is_a?(Relationship)

    SocialAgent::Picker.current_links(Relationship.published.where(id: subject.id), Date.current).exists?
  end

  TRIES = 5
  EXCERPT = 6_000

  # The item with its source page's own words added (about EXCERPT characters from where its title starts, else the
  # page's start), and the page's problems (no answer, sensitive, date not on it). [item, problems]
  def self.prepare(item, fetcher)
    # A sensitive subject in the item's own words is skipped before any writing.
    return [ item, [ "it touches a sensitive topic (#{$1.downcase})" ] ] if item.own_text =~ SocialAgent::Rules::SENSITIVE
    return [ item, [ "its source isn't a primary one (#{SocialAgent::Rules.host(item.source_url).presence || 'none'})" ] ] unless SocialAgent::Rules.primary?(item)

    problems = SocialAgent::Rules.source_problems(item.source_url, fetcher, item:)
    return [ item, problems ] if problems.any?

    text = SocialAgent::Rules.article_text(fetcher.get(item.source_url.to_s).body)
    title = item.facts["headline"].to_s.downcase.first(30).presence
    at = (title && text.downcase.index(title)) || 0
    [ item.with(page_text: text[at, EXCERPT].presence), [] ]
  rescue StandardError => error
    [ item, [ "its source didn't answer (#{error.class})" ] ]
  end

  # One post for the platform, or nil when it's off, it's a weekend, today's is done, or there's nothing fresh.
  # Why a run today would write no post, from the cheap checks only (no picking): nil when it would try. For Draft now's
  # notice (DQ, 20 Nov); the same checks as the start of run.
  def self.no_draft_reason(platform, now: Time.current)
    day = now.in_time_zone(ZONE)
    return "switched off" if SocialChannel.for(platform).off?
    return "it's a weekend" if day.on_weekend?
    return "it's a holiday" if SocialAgent::Rules.holiday?(day.to_date)
    "today's post is already done" if SocialPost.used.where(platform:, created_at: day.all_day).exists?
  end

  # drafts_only: the admin's Draft now, which never sends whatever the switch says.
  def self.run(platform, now: Time.current, writer: nil, fetcher: nil, drafts_only: false)
    channel = SocialChannel.for(platform)
    # Every run that writes no post says why (PM, shadow day 20 Nov: silence looked like a failure).
    # A pause the agent made (Buffer's budget, send errors) says its own reason (Copilot).
    return stopped(platform, now, channel.paused_reason.presence || "switched off in Admin > Posts") if channel.off?
    return stopped(platform, now, "a weekend") if now.in_time_zone(ZONE).on_weekend?
    return stopped(platform, now, "a holiday") if SocialAgent::Rules.holiday?(now.in_time_zone(ZONE).to_date)
    # Never write over a graders-approved draft meant for today: if it isn't out, the agent says so and waits for a person.
    return stopped(platform, now, "a graders-approved draft is scheduled for today") if SocialPost.where(platform:, status: "drafted", send_on: now.in_time_zone(ZONE).to_date).exists?
    if SocialAgent::Buffer.budget_spent?
      reason = "Buffer's 30-day request allowance is #{(SocialAgent::Buffer::ALERT_AT * 100).round}% used"
      SocialChannel.where(platform: SocialChannel::PLATFORMS).find_each { |each| each.update!(mode: "off", paused_reason: reason) }
      return stopped(platform, now, reason)
    end
    # Today's done once anything was sent, queued, drafted or failed (a failure may have been ambiguous; Infra).
    return stopped(platform, now, "today's post is done") if SocialPost.used.where(platform:, created_at: now.in_time_zone(ZONE).all_day).exists?

    fetcher ||= DataQuality::Fetcher.new
    # The first usable item whose source page answers, isn't sensitive and carries its date; its page's words go to the
    # writer and the checks (rehearsal, 20 Nov: a title alone hid an MOU). A few at most, so a bad page never ends the day.
    skipped = []
    item = nil
    SocialAgent::Picker.new(platform:, now:).usable.first(TRIES).each do |candidate|
      ready, problems = prepare(candidate, fetcher)
      if problems.empty?
        item = ready
        break
      end
      skipped << problems.first
    end
    return stopped(platform, now, skipped.any? ? "no usable item (#{skipped.uniq.to_sentence})" : "no fresh item") unless item
    post = SocialPost.new(platform:, subject: item.subject, source_url: item.source_url, source_quote: item.source_quote,
      organization_ids: item.organization_ids, link: link(item, platform))
    # Built only now (Copilot): a missing model setting never stops a day with nothing to post.
    problems = write(post, item, platform, writer, fetcher:)
    return post.tap { |blocked| blocked.update!(status: "blocked", reason: problems.to_sentence) } if problems.any?
    return post.tap { |draft| draft.update!(status: "drafted") } unless channel.live? && sending_enabled? && !drafts_only

    send_post(post, now:)
  end

  STOPPED = "social_agent".freeze

  # A run that wrote no post, kept as a finished run with its platform and why (shown in /api/dq/social_posts). nil.
  def self.stopped(platform, now, why)
    CrawlRun.create!(source_kind: STOPPED, stage: "verify", status: "succeeded", started_at: now, finished_at: now,
      stats: { "platform" => platform, "stopped" => why })
    nil
  end

  # Drafts and checks the post; the problems, empty when it passes. A model or budget error stops this post, logged,
  # and never the job (Copilot); its usage counts toward the DQ budget through its own run.
  def self.write(post, item, platform, writer, fetcher:)
    run = CrawlRun.create!(source_kind: "social_agent", stage: "verify", started_at: Time.current)
    writer ||= SocialAgent::Writer.new
    problems = nil
    # Up to two revisions: the writer sees what stopped its first draft and tries again; every check runs again (rehearsal,
    # 20 Nov: most stops were the writer's slips the checks named exactly).
    [ nil, :revise, :revise ].each do |pass|
      break if pass && problems.empty?

      post.text = writer.draft(item, platform:, crawl_run: run, **(pass ? { feedback: problems.to_sentence, previous: post.text } : {}))
      problems = SocialAgent::Check.problems(post.text, item, platform:)
      problems = SocialAgent::Rules.problems(post.text, item, platform:, fetcher:) if problems.empty?
      if problems.empty?
        ok, why = writer.voice_ok?(post.text, item, crawl_run: run)
        problems << "voice check: #{why}" unless ok
      end
    end
    run.finish!
    problems
  rescue DataQuality::OpenRouter::Client::Error, DataQuality::Config::ConfigurationError, DataQuality::Budget::Exceeded => error
    run&.fail!(error.message)
    [ "couldn't write it: #{error.message.truncate(150)}" ]
  end

  # Sends once: under the channel's lock, checks the month's spend, writes the post as sending (one per item and
  # platform, ever), then calls the platform. No retry.
  def self.send_post(post, now: Time.current)
    claimed = SocialChannel.transaction do
      SocialChannel.lock.find_by!(platform: post.platform)
      month = SocialPost.where(platform: post.platform, status: SocialPost::SENT, created_at: now.all_month)
      next post.tap { |over| over.update!(status: "blocked", reason: "this month's #{monthly_max} posts are done") } if month.count >= monthly_max

      spent = month.sum(:cost_usd)
      next post.tap { |over| over.update!(status: "blocked", reason: "this month's cap of $#{monthly_cap.to_s('F')} is reached") } if spent + post_cost > monthly_cap

      post.update!(status: "sending", cost_usd: post_cost)
    end
    return post unless claimed == true

    # Its fact still published at send time (it may have been taken off since the pick).
    unless still_published?(post.subject.reload)
      return post.tap { |gone| gone.update!(status: "blocked", cost_usd: 0, reason: "its #{{ 'NewsItem' => 'news item', 'Relationship' => 'link' }.fetch(post.subject_type, 'company')} is no longer published") }
    end
    sender = senders[post.platform] or return post.tap { |failed| failed.update!(status: "failed", reason: "#{post.platform} isn't connected") }
    sent = sender.call(post.text, post.link)
    if sent[:permalink]
      post.tap { |done| done.update!(status: "posted", external_id: sent[:id], permalink: sent[:permalink], posted_at: Time.current) }
    else
      post.tap { |queued| queued.update!(status: "queued", external_id: sent[:id], posted_at: sent[:due_at]) }
    end
  rescue ActiveRecord::RecordNotUnique
    post.tap { |again| again.update!(status: "blocked", reason: "already sent once") }
  rescue Uncertain => error
    post.tap { |unknown| unknown.update!(status: "unknown", reason: "may have gone out (#{error.message}); check the account, never resent".truncate(250)) }
      .tap { pause_after_errors(post.platform) }
  rescue StandardError => error
    post.tap { |failed| failed.update!(status: "failed", cost_usd: 0, reason: "#{error.class}: #{error.message}".truncate(250)) }
      .tap { pause_after_errors(post.platform) }
  end

  # Admin > Posts "Send this draft" (#879, PM: Tosin sends the graded draft himself): that exact draft, through the same send as the
  # agent's, after every guard the agent has. Returns [post, nil] when it was handed on, or [post, why] when something refused it
  # (nothing is sent then). The platform's switch may be Drafts only (his click is the approval) but never Off.
  APPROVED = "approved by hand".freeze
  def self.draft_fetcher = @draft_fetcher ||= DataQuality::Fetcher.new
  class << self
    attr_writer :draft_fetcher
  end

  def self.send_draft(post, now: Time.current, fetcher: draft_fetcher)
    refusal = draft_refusal(post, now) || recheck(post, now, fetcher)
    return [ post, refusal ] if refusal

    # Under the channel lock the agent's send takes (Infra, Copilot): the guards are read again from what is stored, and the draft is
    # claimed (drafted -> sending, which also takes the day's slot) before the lock is released, so two clicks, or two drafts, can't both pass.
    # The reason marks it as approved by hand, so the sync keeps it queued in Drafts only mode.
    why = SocialChannel.transaction do
      SocialChannel.for(post.platform).lock!
      next draft_refusal(post.reload, now) ||
        (SocialPost.where(id: post.id, status: "drafted").update_all(status: "sending", reason: (post.graded? ? post.reason : APPROVED), updated_at: Time.current) == 1 ? nil : "it is already being sent, or was sent")
    end
    return [ post.reload, why ] if why

    sent = send_post(post.reload, now:)
    [ sent, (sent.reason.presence || "it didn't send" if sent.status.in?(%w[blocked failed unknown])) ]
  end

  # The stored text checked again against the item and its source as they stand now (DQ): the facts may have changed since the draft.
  # The voice check is a model call and isn't repeated. Sets the post blocked when a check no longer passes.
  def self.recheck(post, now, fetcher)
    # A graders-approved draft keeps its hash as the control; only its source still answering is looked at again (DQ): a release taken down
    # or moved after approval stops the send, and the draft stays so it can be sent when it answers again.
    if post.graded?
      return if post.source_url.blank?

      response = fetcher.get(post.source_url)
      return if response.kind == :ok && response.status == 200

      return "its source page no longer answers (#{response.status || response.reason})"
    end

    item = SocialAgent::Picker.new(platform: post.platform, now:).candidates.find { |candidate| candidate.subject == post.subject }
    return "its item is no longer one the agent could post" unless item

    ready, problems = prepare(item, fetcher)
    problems = SocialAgent::Check.problems(post.text, ready, platform: post.platform) if problems.empty?
    problems = SocialAgent::Rules.problems(post.text, ready, platform: post.platform, fetcher:, except_id: post.id) if problems.empty?
    return if problems.empty?

    post.update!(status: "blocked", reason: problems.to_sentence)
    "its checks no longer pass: #{problems.to_sentence}"
  end

  def self.draft_refusal(post, now)
    day = now.in_time_zone(ZONE)
    channel = SocialChannel.for(post.platform)
    window = ->(scope) { scope.where.not(id: post.id) }
    return "only a draft that passed every check can be sent (this one is #{post.status})" unless post.status == "drafted"
    return "sending is off on the server (SOCIAL_POSTING_ENABLED)" unless sending_enabled?
    return "#{post.platform == 'x' ? 'X' : 'LinkedIn'} is switched off in Admin > Posts#{(': ' + channel.paused_reason) if channel.paused_reason.present?}" if channel.off?
    return "it's a weekend" if day.on_weekend?
    return "it's a holiday" if SocialAgent::Rules.holiday?(day.to_date)
    # A graders-approved draft names its day (send_on: the 8:30 job sends it that morning); any other draft must be from today.
    if post.graded? && post.send_on
      return "this approved draft is for #{post.send_on.strftime('%-d %b')}, not today" unless post.send_on == day.to_date
    elsif post.created_at.in_time_zone(ZONE).to_date != day.to_date
      return "this draft is from #{post.created_at.in_time_zone(ZONE).strftime('%-d %b')}: draft again today so the facts and checks are fresh"
    end
    return "Buffer's 30-day request allowance is used up" if SocialAgent::Buffer.budget_spent?
    return "today's slot for this platform is already taken (a post or an attempt)" if window.(SocialPost.used.where(platform: post.platform, created_at: day.all_day)).exists?
    return "the same item was posted or tried within the last #{SocialPost::COOLDOWN.inspect}" if window.(SocialPost.where.not(status: "cancelled").where(subject: post.subject, created_at: (now - SocialPost::COOLDOWN)..)).exists?
    return "a post about the same company was posted or tried today" if window.(SocialPost.where.not(status: "cancelled").where(created_at: day.all_day)).where("organization_ids && ARRAY[?]::bigint[]", post.organization_ids).exists?
    return "its item is no longer published" unless still_published?(post.subject.reload)

    nil
  end

  # The 8:30 job's first step (PM, #897): today's graders-approved draft for the platform, if one is scheduled (send_on), goes out even when the
  # platform is on Drafts only; every guard of Send this draft still applies, so Off, the server switch, the caps and the rest stop it. Says why when it
  # doesn't go.
  def self.send_scheduled(platform, now: Time.current, fetcher: nil)
    day = now.in_time_zone(ZONE).to_date
    post = SocialPost.where(platform:, status: "drafted", send_on: day).order(:id).detect(&:graded?) or return
    sent, why = send_draft(post, now:, fetcher: fetcher || draft_fetcher)
    return stopped(platform, now, "approved draft #{post.id} not sent: #{why}") if why

    sent
  end

  # Takes back every queued post not yet out, for the platform (or all): the kill switch (PM: it stops dispatch
  # and cancels what's queued). A post the publisher won't take back stays queued and says why.
  # keep_approved: a draft Tosin sent by hand stays queued when the platform is only Drafts only (not Live), never when it is Off.
  def self.cancel_queued(platform: nil, why: "switched off", publisher: self.publisher, keep_approved: false)
    queued = SocialPost.where(status: "queued").where(posted_at: Time.current..)
    queued = queued.where(platform:) if platform
    queued = queued.where("reason IS NULL OR (reason <> ? AND reason NOT LIKE ?)", APPROVED, "#{SocialPost::GRADED}%") if keep_approved
    queued.find_each do |post|
      publisher.cancel(post.external_id)
      post.update!(status: "cancelled", cost_usd: 0, reason: "taken back before it went out: #{why}")
    rescue StandardError => error
      post.update!(reason: "couldn't take it back (#{error.message.truncate(120)}): remove it in Buffer")
    end
  end

  # Every few minutes: the switch is honoured (a platform not live, or sending off on the server, takes back what's
  # queued), and queued posts that are due are read back: sent with their link, or an error.
  def self.sync(publisher: self.publisher)
    SocialChannel.where(platform: SocialChannel::PLATFORMS).find_each do |channel|
      cancel_queued(platform: channel.platform, why: "switched off", publisher:, keep_approved: !channel.off? && sending_enabled?) unless channel.live? && sending_enabled?
    end
    SocialPost.where(status: "queued").where(posted_at: ..2.minutes.ago).find_each do |post|
      state = publisher.status(post.external_id)
      case state[:status]
      when "sent" then post.update!(status: "posted", permalink: state[:link])
      when "error"
        post.update!(status: "failed", reason: "the publisher couldn't post it")
        pause_after_errors(post.platform)
      end
    rescue StandardError => error
      Rails.logger.warn("[social] couldn't read post #{post.id} back: #{error.message}")
    end
  end

  # Two sends in a row that errored switch the platform off (Infra); a person looks, then turns it back on.
  PAUSE_AFTER = 2
  def self.pause_after_errors(platform)
    last = SocialPost.where(platform:, status: %w[queued posted unknown failed]).order(id: :desc).limit(PAUSE_AFTER).pluck(:status)
    return unless last.size == PAUSE_AFTER && last.none?("posted")

    SocialChannel.for(platform).update!(mode: "off", paused_reason: "#{PAUSE_AFTER} sends in a row didn't go through")
  end

  # Our own page for the item (the company or plant it belongs to), never the source's URL, tracked: utm_source x or
  # linkedin, utm_medium social, utm_campaign the page's slug (Tosin, 20 Nov).
  def self.link(item, platform)
    "#{SITE}#{item.path}?utm_source=#{platform}&utm_medium=social&utm_campaign=#{item.path.to_s.split('/').last}"
  end
end
