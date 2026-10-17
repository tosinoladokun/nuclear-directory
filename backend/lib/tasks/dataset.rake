namespace :dataset do
  desc "Dry run of the open dataset (#254): write every published fact and its sources to DIR (default tmp/dataset)"
  task export: :environment do
    dir = ENV.fetch("DIR", Rails.root.join("tmp/dataset").to_s)
    counts = Dataset::Export.new(dir).write!
    counts.each { |name, count| puts "#{name.ljust(14)} #{count}" }
    puts "Written to #{dir}. A dry run: nothing is published."
  end
end
