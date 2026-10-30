# How many published companies are complete for the 30 Nov outcome (PM, 29
# Oct): each has a category (it's in at least one industry group, as the
# lists show it), a website, a description and a headquarters state. Read
# only: a count for the Monday check, and each incomplete company's missing
# parts as Data Quality's worklist.
#
#   report = Completeness.new
#   report.complete_count # => 36
#   report.total          # => 157
#   report.rows           # => [Completeness::Row, …], least complete first
class Completeness
  PARTS = %w[category website description hq].freeze
  Row = Data.define(:slug, :name, :missing) do
    def complete? = missing.empty?
  end

  def rows
    @rows ||= begin
      in_a_group = Category.buckets.flat_map { |category| Organization.where(id: Bucket.organization_ids(category)).pluck(:id) }.to_set
      Organization.published.order(:name).pluck(:id, :slug, :name, :website, :description, :hq_state).map do |id, slug, name, website, description, hq|
        missing = { "category" => in_a_group.include?(id), "website" => website.present?, "description" => description.present?,
                    "hq" => hq.present? }.reject { |_, present| present }.keys
        Row.new(slug:, name:, missing:)
      end.sort_by { |row| [ -row.missing.size, row.name ] }
    end
  end

  def total = rows.size
  def complete_count = rows.count(&:complete?)
  def missing_counts = PARTS.index_with { |part| rows.count { |row| row.missing.include?(part) } }

  def to_csv
    CSV.generate do |csv|
      csv << [ "slug", "name", *PARTS.map { |part| "missing_#{part}" } ]
      rows.reject(&:complete?).each { |row| csv << [ row.slug, row.name, *PARTS.map { |part| row.missing.include?(part) ? "yes" : "" } ] }
    end
  end
end
