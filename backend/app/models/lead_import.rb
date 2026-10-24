# Data Quality's Leads.md (#484): one markdown table, a row per lead, with
# the header | Lead | Kind | Came from | First seen | Count | Status | Next step |.
# Each row's names (split on ';', a parenthetical kept as a note, not a
# name) become leads with the row's text kept. Once per row: a lead that
# exists keeps whatever was decided on the page; importing again only adds
# new leads and fills a blank note. Statuses: new, researching, seeded (in a
# seed PR: being researched), added, dead (ignored, with the reason after the colon).
class LeadImport
  HEADER = %w[lead kind came\ from first\ seen count status next\ step].freeze
  KINDS = { "company" => "company", "plant" => "plant", "search" => "other", "news name" => "other" }.freeze
  STATUSES = { "new" => "new", "researching" => "researching", "seeded" => "researching", "added" => "added", "dead" => "ignored" }.freeze

  Row = Data.define(:names, :kind, :came_from, :first_seen, :count, :status, :reason, :note)

  def self.table?(text) = !header_index(text.to_s.lines).nil?

  def self.header_index(lines)
    lines.index { |line| cells(line).map(&:downcase) == HEADER }
  end

  def self.cells(line) = line.strip.delete_prefix("|").delete_suffix("|").split("|").map(&:strip)

  def self.rows(text)
    lines = text.to_s.lines
    start = header_index(lines) or return []
    lines.drop(start + 1).filter_map do |line|
      next unless line.strip.start_with?("|")

      lead, kind, came_from, first_seen, count, status, next_step = cells(line)
      next if lead.to_s.match?(/\A:?-{3,}/) || lead.blank?

      notes = lead.scan(/\(([^)]*)\)/).flatten
      names = lead.gsub(/\([^)]*\)/, "").split(";").map(&:squish).reject(&:empty?)
      word, detail = status.to_s.split(/\s*:\s*|\s+/, 2)
      mapped = STATUSES[word.to_s.downcase] || "new"
      reason = (detail.to_s.squish.presence || "dead") if mapped == "ignored"
      note = [ *notes, ("Status: #{status.squish}" if status.to_s.squish.length > word.to_s.length && mapped != "ignored"),
        ("Next: #{next_step.squish}" if next_step.present?) ].compact.join(" · ").presence
      first = (Date.parse(first_seen) unless first_seen.to_s.strip.in?([ "", "-", "–" ])) rescue nil
      Row.new(names:, kind: KINDS[kind.to_s.downcase.squish] || "other", came_from: came_from.to_s.squish.presence || "Leads.md",
        first_seen: first || Date.current, count: [ count.to_s[/\d+/].to_i, 1 ].max, status: mapped, reason:, note:)
    end
  end

  # Imports the table; returns how many leads it wrote.
  def self.import!(text, by:)
    rows(text).sum do |row|
      row.names.count do |name|
        existed = Lead.exists?(kind: row.kind, normalized_name: Lead.normalize(name))
        lead = Lead.sighted!(name:, kind: row.kind, key: "leads-md:#{Lead.normalize(name)}", label: row.came_from, times: row.count,
          first: row.first_seen) or next false
        if existed
          # Never over a decision made on the page: only a blank note is filled.
          lead.update!(note: row.note) if lead.note.blank? && row.note.present?
        else
          lead.update!(status: row.status, reason: row.reason, note: row.note, decided_by: (by unless row.status == "new"),
            decided_at: (Time.current unless row.status == "new"))
        end
        true
      end
    end
  end
end
