namespace :usage do
  desc "Top pages, top searches and searches with no results over the last DAYS days (default 30)"
  task :report, [ :days ] => :environment do |_task, args|
    days = Integer(args[:days] || 30)
    since = Date.current - (days - 1)

    puts "Usage, #{since} to #{Date.current} (#{days} days). Anonymous daily counts; no visitor data is stored."
    {
      "Top pages" => :page_view,
      "Top searches" => :search,
      "Searches with no results" => :search_no_results
    }.each do |title, event|
      rows = UsageCount.top(event, since: since)
      puts "\n#{title} (#{UsageCount.public_send(event).since(since).sum(:count)} total)"
      puts "  (none yet)" if rows.empty?
      rows.each { |key, count| puts format("  %6d  %s", count, key) }
    end
  end
end
