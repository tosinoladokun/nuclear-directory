# The checker's exam (#776): DQ's own verdicts (a JSON-lines file kept outside the repo) against the
# checker's, run locally with a key. A stratified 150 is frozen once (by kind and verdict, ids kept next to
# the file) and never tuned on; the full set is for tuning.
#
#   bin/rails "checker:exam[tmp/exam_set.jsonl,frozen]"   # or all; writes <file>.report-<set>.md
#
# Pass to shadow (DQ): no approval of anything DQ rejected, >= 95% of DQ's approves answered approve or
# unsure, and unsure under 35%.
class DqChecker::Exam
  FROZEN = 150
  SEED = 776

  Row = Data.define(:id, :field, :dq, :dq_reason, :answer, :page)

  def initialize(path, checker: DqChecker.new)
    @path = path
    @checker = checker
    @rows = File.readlines(path).filter_map { |line| JSON.parse(line) if line.strip.present? }
  end

  # The frozen ids, made once: per (kind, verdict), its share of FROZEN, at least one.
  def frozen_ids
    file = "#{@path}.frozen_ids.json"
    return JSON.parse(File.read(file)) if File.exist?(file)

    random = Random.new(SEED)
    strata = @rows.group_by { |row| [ row["kind"], row["verdict"] ] }
    ids = strata.sort.flat_map do |_, rows|
      take = [ (rows.size * FROZEN.to_f / @rows.size).round, 1 ].max
      rows.sort_by { |row| row["candidate_id"] }.shuffle(random: random).first(take).map { |row| row["candidate_id"] }
    end
    ids = ids.first(FROZEN).sort
    File.write(file, JSON.generate(ids))
    ids
  end

  def run(set)
    rows = set == "all" ? @rows : @rows.select { |row| row["candidate_id"].in?(frozen_ids) }
    run = CrawlRun.create!(source_kind: "dq_checker_exam", stage: "verify", prompt_version: DqChecker::PROMPT_VERSION)
    @checker.run = run
    results = rows.map do |row|
      claim, page = claim_for(row)
      Row.new(id: row["candidate_id"], field: claim.field, dq: row["verdict"], dq_reason: row["reason"], answer: @checker.judge(claim), page:)
    end
    run.finish!
    report(results, set, run.reload.stats.dig("llm", "cost").to_f)
  end

  def claim_for(row)
    candidate = Candidate.find_by(id: row["candidate_id"], kind: row["kind"])
    stored = candidate && @checker.window(candidate)
    org = candidate&.subject if candidate&.subject_type == "Organization"
    page = stored.presence || row["quote"]
    claim = DqChecker::Claim.new(id: row["candidate_id"], kind: row["kind"], payload: row["payload"], quote: row["quote"], source_kind: row["source_kind"],
      page:, holding: @checker.holding(org), hold: nil)
    [ claim, stored.present? ? "page" : "quote only" ]
  end

  def report(results, set, cost)
    lines = [ "# Checker exam (#{set}, #{results.size} claims, #{DqChecker::PROMPT_VERSION}), cost $#{cost.round(4)}", "" ]
    lines << "| Field | Claims | DQ approves kept (approve or unsure) | Approvals of DQ rejects | Unsure |"
    lines << "| --- | --- | --- | --- | --- |"
    results.group_by(&:field).sort.push([ "all", results ]).each do |field, rows|
      approves = rows.select { |row| row.dq == "approve" }
      kept = approves.count { |row| row.answer.verdict != "reject" }
      bad = rows.count { |row| row.dq == "reject" && row.answer.verdict == "approve" }
      unsure = rows.count { |row| row.answer.verdict == "unsure" }
      lines << "| #{field} | #{rows.size} | #{kept}/#{approves.size} (#{pct(kept, approves.size)}) | #{bad} | #{unsure} (#{pct(unsure, rows.size)}) |"
    end
    lines += [ "", "## Every disagreement", "", "| Claim | Field | DQ | Checker | Checker's reason | DQ's reason | Read |", "| --- | --- | --- | --- | --- | --- | --- |" ]
    results.reject { |row| row.answer.verdict == row.dq || row.answer.verdict == "unsure" }.each do |row|
      lines << "| #{row.id} | #{row.field} | #{row.dq} | #{row.answer.verdict}#{' (escalated)' if row.answer.escalated} | #{cell(row.answer.reason)} | #{cell(row.dq_reason)} | #{row.page} |"
    end
    lines += [ "", "## Unsure", "", "| Claim | Field | DQ | Checker's reason |", "| --- | --- | --- | --- |" ]
    results.select { |row| row.answer.verdict == "unsure" }.each do |row|
      lines << "| #{row.id} | #{row.field} | #{row.dq} | #{cell(row.answer.reason)} |"
    end
    lines.join("\n") + "\n"
  end

  private
    def pct(part, whole) = whole.zero? ? "n/a" : "#{(100.0 * part / whole).round(1)}%"
    def cell(text) = text.to_s.gsub("|", "/").squish.truncate(160)
end
