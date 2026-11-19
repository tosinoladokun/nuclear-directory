namespace :checker do
  desc "Run the nightly checker's exam (#776) on DQ's verdicts: checker:exam[path,frozen|all]; writes a report next to the file"
  task :exam, %i[path set] => :environment do |_, args|
    path = args[:path].presence or abort "Give the exam file: checker:exam[tmp/exam_set.jsonl,frozen]"
    set = args[:set].presence || "frozen"
    abort "The set is frozen or all" unless set.in?(%w[frozen all])

    report = DqChecker::Exam.new(path).run(set)
    out = "#{path}.report-#{set}.md"
    File.write(out, report)
    puts report.split("\n## ").first
    puts "Report: #{out}"
  end
end
