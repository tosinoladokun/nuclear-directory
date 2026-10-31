namespace :directory do
  desc "How many published companies are complete (category, website, description, HQ) for the 30 Nov outcome; " \
    "CSV=path writes each incomplete company's missing parts"
  task completeness: :environment do
    report = Completeness.new
    puts "Complete: #{report.complete_count}/#{report.total} published companies (category, website, description, HQ)"
    report.missing_counts.each { |part, count| puts "  missing #{part}: #{count}" }
    if (path = ENV["CSV"].presence)
      File.write(path, report.to_csv)
      puts "Worklist (#{report.total - report.complete_count} companies) written to #{path}"
    end
  end
end
