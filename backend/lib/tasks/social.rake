namespace :social do
  desc "Rehearse the social agent (no posting): social:rehearse[N,days] drafts and checks N items per platform plus the fixed cases"
  task :rehearse, %i[per_platform days] => :environment do |_, args|
    results = SocialAgent::Rehearsal.new(per_platform: (args[:per_platform].presence || 10).to_i,
      days: (args[:days].presence || SocialAgent::Rehearsal::DAYS).to_i).run
    dir = Rails.root.join("tmp/rehearsal")
    FileUtils.mkdir_p(dir)
    stamp = Time.current.utc.strftime("%Y%m%d-%H%M")
    File.write(dir.join("#{stamp}.md"), SocialAgent::Rehearsal.report(results))
    File.write(dir.join("#{stamp}.json"), JSON.pretty_generate(results.map(&:to_h)))
    results.group_by(&:platform).each { |platform, rows| puts "#{platform}: #{rows.count(&:passed?)}/#{rows.size} passed" }
    puts "Report: tmp/rehearsal/#{stamp}.md"
  end
end

namespace :social do
  desc "Per-item PASS/BLOCK history across rehearsal rounds: social:consistency[dir] reads dir/*.json (default tmp/rehearsal)"
  task :consistency, [ :dir ] => :environment do |_, args|
    dir = Pathname(args[:dir].presence || Rails.root.join("tmp/rehearsal"))
    puts SocialAgent::Rehearsal.consistency(Dir[dir.join("*.json")])
  end
end

namespace :social do
  desc "Load the directory's public updates feed into this (empty, local) database for social:rehearse"
  task load_public: :environment do
    abort "Local only: never in production" if Rails.env.production?
    loaded = SocialRehearsal::PublicLoad.new.call
    puts "Loaded #{loaded.news} news items and #{loaded.links} links; skipped #{loaded.skipped.size}: #{loaded.skipped.first(10).join('; ')}"
  end
end
