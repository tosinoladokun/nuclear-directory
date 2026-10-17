namespace :deploy_data do
  # Run by bin/deploy-data (Render's pre-deploy step, after db:migrate); see
  # DeployData::Run. DRY_RUN=1 rolls everything back: Data Quality's
  # rehearsal on a restored backup.
  desc "The deploy's data step: backup, seed:check, db:seed, data migrations, report (DRY_RUN=1 to rehearse)"
  task run: :environment do
    # bin/deploy-data's timeout sends TERM: stop where we are (the open
    # transaction rolls back), then report it.
    Signal.trap("TERM") { Thread.main.raise(DeployData::Run::TimedOut, "took longer than bin/deploy-data allows") }
    status = DeployData::Run.new(dry_run: ENV["DRY_RUN"] == "1").call
    exit 1 if %i[stopped failed].include?(status)
  end
end
