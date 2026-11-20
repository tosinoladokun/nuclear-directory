# A rehearsal of the social agent (PM, 20 Nov): every eligible item of the last DAYS, plus fixed cases, drafted and
# checked exactly as a real run does, per platform, and never posted: no SocialPost is saved and no day's slot is used.
# The report (markdown and JSON) shows each draft's text, whether it passed, why not, and its source.
#
#   bin/rails "social:rehearse[10]"   # 10 drafts per platform; writes tmp/rehearsal/<time>.{md,json}
#
# Model calls are real (they're counted in CrawlRuns like any run): run it on a local database restored from a backup.
class SocialAgent::Rehearsal
  DAYS = 30
  FIXTURES = Rails.root.join("test/fixtures/files/social_rehearsal.yml")

  Result = Data.define(:platform, :label, :kind, :text, :problems, :source_url, :date) do
    def passed? = problems.empty?
  end

  def initialize(per_platform:, days: DAYS, now: Time.current, writer: nil, fetcher: DataQuality::Fetcher.new)
    @per_platform = per_platform
    @days = days
    @now = now
    @writer = writer
    @fetcher = fetcher
  end

  def run
    SocialChannel::PLATFORMS.flat_map do |platform|
      items = fixtures + SocialAgent::Picker.new(platform:, now: @now, fresh: @days.days).candidates.map { |item| [ label(item), item ] }
      items.first(@per_platform + fixtures.size).map do |label, item|
        post = SocialPost.new(platform:)
        item, problems = SocialAgent.prepare(item, @fetcher)
        problems = SocialAgent.write(post, item, platform, @writer, fetcher: @fetcher) if problems.empty?
        Result.new(platform:, label:, kind: item.kind, text: post.text, problems:, source_url: item.source_url, date: item.facts["date"])
      end
    end
  end

  # Today's shadow drafts and other known cases, as items (no database rows).
  def fixtures
    @fixtures ||= YAML.safe_load_file(FIXTURES).map do |row|
      [ "fixture: #{row['name']}", SocialAgent::Item.new(subject: nil, kind: row["kind"], facts: row["facts"] || {}, source_url: row["source_url"],
        source_quote: row["source_quote"], path: row["path"] || "/", organization_ids: []) ]
    end
  end

  # For Data Quality's grading (20 Nov): each draft as id, platform, exact text, source URL, the item's own date, run ref.
  def self.report(results, run: Time.current.utc.strftime("%Y%m%d-%H%M"))
    lines = [ "# Social rehearsal #{run}", "" ]
    results.group_by(&:platform).each do |platform, rows|
      lines << "## #{platform == 'x' ? 'X' : 'LinkedIn'}: #{rows.count(&:passed?)} of #{rows.size} passed" << ""
      rows.each_with_index do |row, index|
        lines << "### #{run}-#{platform}-#{index + 1} #{platform} #{row.passed? ? 'PASS' : 'BLOCK'}: #{row.label}"
        lines << "run: #{run}" << "source: #{row.source_url}" << "item date: #{row.date || 'none'}"
        lines << "why: #{row.problems.to_sentence}" unless row.passed?
        lines << "" << row.text.to_s.lines.map { |line| "> #{line.chomp}" }.join("\n") << ""
      end
    end
    lines.join("\n")
  end

  private
    def label(item) = "#{item.kind} #{item.subject&.class&.name} #{item.subject&.id}: #{item.facts.values.first.to_s.truncate(80)}"
end
