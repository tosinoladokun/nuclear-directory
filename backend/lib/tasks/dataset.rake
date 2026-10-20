namespace :dataset do
  desc "Write the open dataset release (#254) to DIR: every published fact, its sources and the files that describe them " \
    "[VERSION=2026.12] [PREVIOUS=<last release's folder>, for the changelog]"
  task export: :environment do
    dir = ENV.fetch("DIR", Rails.root.join("tmp/dataset").to_s)
    result = Dataset::Export.new(dir, version: ENV.fetch("VERSION", Date.current.strftime("%Y.%m")), previous: ENV["PREVIOUS"].presence).write!
    result[:counts].each { |name, count| puts "#{name.ljust(14)} #{count}" }
    if result[:unknown_publishers].any?
      puts "No publisher known for #{result[:unknown_publishers].size} domains (shown as the domain; add them to lib/dataset/publishers.yml):"
      result[:unknown_publishers].each { |host| puts "  #{host}" }
    end
    puts "Written to #{dir}. Nothing is published from here."
  end
end
