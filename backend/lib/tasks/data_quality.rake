namespace :data_quality do
  desc "Put NRC units already enriched by EIA under their EIA plant's site (#73, one-off)"
  task group_units: :environment do
    directory = DataQuality::DirectoryClient.new
    grouped = Candidate.status_merged.where(kind: "facility").where("payload ? 'identify'").filter_map do |candidate|
      result = directory.group_unit(candidate) or next
      puts "#{candidate.subject_type} #{candidate.subject_id}: #{result.errors.join('; ')}" unless result.success?
      result if result.success?
    end
    puts "Grouped #{grouped.size} units under their sites."
  end

  report = ->(runs) do
    runs.each { |run| puts "#{run.stage.ljust(8)} #{run.status.ljust(10)} #{run.stats.to_json}" }
  end

  desc "Run the whole pipeline for a source kind: bin/rails data_quality:run[nrc_reactor_list]"
  task :run, [ :source_kind ] => :environment do |_task, args|
    abort "Usage: bin/rails data_quality:run[source_kind]" if args[:source_kind].blank?

    report.call DataQuality::Pipeline.run(args[:source_kind])
  end

  desc "Run one stage for a source kind: bin/rails data_quality:stage[extract,nrc_reactor_list]"
  task :stage, [ :stage, :source_kind ] => :environment do |_task, args|
    abort "Usage: bin/rails data_quality:stage[stage,source_kind]" if args[:stage].blank? || args[:source_kind].blank?

    report.call DataQuality::Pipeline.run(args[:source_kind], only: args[:stage])
  end

  # Queued for the background worker rather than run here: on Render a second
  # Rails process doing the work would share the instance's 512 MB (#188).
  desc "Re-run extract, match and verify from the stored snapshot, no fetch: bin/rails data_quality:rerun[nrc_reactor_list]"
  task :rerun, [ :source_kind ] => :environment do |_task, args|
    abort "Usage: bin/rails data_quality:rerun[source_kind]" if args[:source_kind].blank?

    DataQuality::Plugin.for(args[:source_kind]) # an unknown kind fails here, not in the job
    DataQuality::RunJob.perform_later(args[:source_kind], only: DataQuality::Pipeline::FROM_SNAPSHOT)
    puts "Queued #{DataQuality::Pipeline::FROM_SNAPSHOT.join(', ')} for #{args[:source_kind]} " \
      "from its stored snapshot. Follow it with: bin/rails data_quality:status"
  end

  # #197: units approved with NRC's state, which is its reference city's.
  # Goes through the Review API as the named person, so the change and its
  # reason are in the unit's history like any admin decision.
  desc "Correct an NRC unit's state, audited: BY=human:tosin bin/rails \"data_quality:correct_unit_state[05000354,NJ]\""
  task :correct_unit_state, [ :nrc_docket, :state ] => :environment do |_task, args|
    by = ENV["BY"].to_s
    abort "Usage: BY=human:<handle> bin/rails \"data_quality:correct_unit_state[nrc_docket,STATE]\"" unless
      by.match?(/\Ahuman:\S+\z/) && args[:nrc_docket].present? && args[:state].to_s.match?(/\A[A-Z]{2}\z/)

    directory = DataQuality::DirectoryClient.new
    unit = directory.facility(nrc_docket: args[:nrc_docket]) or abort "No unit with NRC docket #{args[:nrc_docket]}"
    # A published unit only: approving would also publish a pending or taken-down one.
    unless unit.verification_status == "verified"
      abort "#{unit.name} isn't published (#{unit.verification_status}), so its state isn't corrected here"
    end
    reason = "State corrected from #{unit.state.presence || 'blank'} to #{args[:state]}: NRC's Location is measured from a " \
      "nearby city in another state; EIA-860M lists the plant in #{args[:state]} (#197)"
    result = DataQuality::Review.approve_fact(type: "Facility", id: unit.id, by:, reason:, attributes: { "state" => args[:state] },
      directory:)
    abort "#{unit.name}: #{result.errors.to_sentence}" unless result.ok?

    puts "#{unit.name} (#{unit.nrc_docket}): state #{directory.facility(id: unit.id).state}, recorded as #{by}"
  end

  # #228: candidates rejected for a reason that no longer holds go back to
  # the queue through the Review API, with who and why kept on each.
  desc "Reopen rejected candidates, audited: BY=human:tosin REASON=\"…\" IDS=243,244 bin/rails data_quality:reopen"
  task reopen: :environment do
    by, reason = ENV["BY"].to_s, ENV["REASON"].to_s
    ids = ENV["IDS"].to_s.split(",").map(&:strip)
    abort "Usage: BY=human:<handle> REASON=\"why\" IDS=1,2 bin/rails data_quality:reopen" unless
      by.match?(/\Ahuman:\S+\z/) && reason.present? && ids.any? && ids.all? { |id| id.match?(/\A\d+\z/) }

    results = DataQuality::Review.reopen(ids.map(&:to_i), by:, reason:)
    results.each { |result| puts "Candidate #{result.candidate_id}: #{result.ok? ? 'reopened' : result.errors.to_sentence}" }
    (ids.map(&:to_i) - results.map(&:candidate_id)).each { |id| puts "Candidate #{id}: not found" }
    # Queued in the worker, not run in this shell (Render's 512 MB limit).
    kinds = Candidate.where(id: results.select(&:ok?).map(&:candidate_id)).joins(:source).distinct.pluck("sources.source_kind")
    kinds.each { |kind| puts "Next: bin/rails \"data_quality:rerun[#{kind}]\", then review them in the admin." }
  end

  # #226: 24 link approvals were written onto other links. Dry run unless
  # APPLY=1; every change is recorded as the named person.
  desc "Repair #226 (misplaced link evidence), audited: BY=human:tosin [APPLY=1] bin/rails data_quality:repair_226"
  task repair_226: :environment do
    by = ENV["BY"].to_s
    abort "Usage: BY=human:<handle> [APPLY=1] bin/rails data_quality:repair_226" unless by.match?(/\Ahuman:\S+\z/)

    apply = ENV["APPLY"] == "1"
    outcomes = DataQuality::Repairs::MisplacedLinkEvidence.call(items: DataQuality::Repairs::MisplacedLinkEvidence::ISSUE_226,
      by:, dry_run: !apply)
    outcomes.each { |outcome| puts "candidate #{outcome.candidate_id.to_s.ljust(4)} #{outcome.status.to_s.ljust(16)} #{outcome.message}" }
    counts = outcomes.group_by(&:status).transform_values(&:size)
    puts counts.map { |status, count| "#{count} #{status.to_s.tr('_', ' ')}" }.join(", ")
    puts "Dry run: nothing changed. Run again with APPLY=1 to apply." unless apply
    abort "Some items were skipped; see above." if counts.key?(:skipped)
  end

  # #240: open candidates that only restate a decided fact are closed as
  # "confirmed", not approved again. Dry run unless APPLY=1.
  desc "Close open candidates identical to decided facts, audited: BY=human:tosin [APPLY=1] [IDS=1,2] bin/rails data_quality:confirm_identical"
  task confirm_identical: :environment do
    by = ENV["BY"].to_s
    ids = ENV["IDS"].to_s.split(",").map(&:strip)
    abort "Usage: BY=human:<handle> [APPLY=1] [IDS=1,2] bin/rails data_quality:confirm_identical" unless
      by.match?(/\Ahuman:\S+\z/) && ids.all? { |id| id.match?(/\A\d+\z/) }

    apply = ENV["APPLY"] == "1"
    results = DataQuality::Review.confirm_identical(ids.presence&.map(&:to_i), by:, dry_run: !apply)
    results.reject(&:ok?).each { |result| puts "candidate #{result.candidate_id.to_s.ljust(5)} stays open: #{result.errors.to_sentence}" }
    confirmed, open = results.partition(&:ok?)
    puts "#{confirmed.size} #{apply ? 'confirmed' : 'would be confirmed'}, #{open.size} stay open"
    puts "Dry run: nothing changed. Run again with APPLY=1 to apply." unless apply
  end

  # #302: the DOE award claims still open take the plug-in's new wording and
  # names. The DOE crawl does this itself at the start of each run
  # (UsaspendingDoeAwards#refresh_open_claims); this shows what it would
  # change, for a rehearsal on a restored backup. Dry run unless APPLY=1.
  desc "Show (or with APPLY=1 make) the #302 rewording of open DOE award claims, audited: BY=human:tosin [APPLY=1] bin/rails data_quality:refresh_doe_awards"
  task refresh_doe_awards: :environment do
    by = ENV["BY"].to_s
    abort "Usage: BY=human:<handle> [APPLY=1] bin/rails data_quality:refresh_doe_awards" unless by.match?(/\Ahuman:\S+\z/)

    apply = ENV["APPLY"] == "1"
    refreshed = []
    ActiveRecord::Base.transaction(requires_new: true) do
      refreshed = DataQuality::Plugin.for("usaspending_doe_awards").refresh_open_claims(by:)
      refreshed.each do |item|
        changes = item[:changes].map { |key, value| "#{key} -> #{value.inspect}" }.join("; ")
        puts "candidate #{item[:candidate].id.to_s.ljust(5)} #{item[:candidate].kind}: #{changes}#{' (back to verify)' if item[:reverify]}"
      end
      raise ActiveRecord::Rollback unless apply
    end
    verb = apply ? "" : "would be "
    puts "#{refreshed.size} claims #{verb}reworded, #{refreshed.count { |item| item[:reverify] }} #{verb}sent back to verify."
    puts "Dry run: nothing changed. The next DOE crawl makes these changes itself." unless apply
  end

  # For bin/deploy-data (#301): its data steps in one process, holding the
  # data write lock exclusively, so no crawl writes meanwhile. The lock
  # belongs to this process's database session, so the steps run here, one
  # after another, rather than as separate commands.
  desc "Run rake tasks holding the data write lock (#301): TASKS=\"seed:check db:seed\" [WAIT_MINUTES=30] bin/rails data_quality:with_write_lock"
  task with_write_lock: :environment do
    tasks = ENV["TASKS"].to_s.split
    abort "Usage: TASKS=\"task another:task\" [WAIT_MINUTES=30] bin/rails data_quality:with_write_lock" if tasks.empty?

    DataQuality::WriteLock.exclusive(timeout: ENV.fetch("WAIT_MINUTES", "30").to_i.minutes) do
      tasks.each { |name| Rake::Task[name].invoke }
    end
  rescue DataQuality::WriteLock::Busy => error
    abort "Not run: #{error.message}"
  end

  desc "Check the OpenRouter key works, without a model call: bin/rails data_quality:check_key"
  task check_key: :environment do
    key = DataQuality::OpenRouter::Client.new.check_key
    limit = key[:limit] ? format("$%.2f", key[:limit]) : "no limit"
    puts "OpenRouter key OK (#{key[:label] || 'unlabelled'}): used #{format('$%.2f', key[:usage].to_f)} of #{limit}"
  rescue DataQuality::OpenRouter::Client::Error, DataQuality::Config::ConfigurationError => error
    abort "OpenRouter key check failed: #{error.message}"
  end

  desc "How the pipeline is doing: blocked sources, last runs, review queue, model spend"
  task status: :environment do
    puts DataQuality::StatusReport.call
  end

  desc "One-off: fetch a title for every source that has none (#64), politely"
  task backfill_titles: :environment do
    stats = DataQuality::TitleBackfill.run(log: ->(line) { puts line })
    puts stats.to_json
  end
end
