# Reads the table on NRC's "Locations of Power Reactor Sites Undergoing
# Decommissioning" page: one Row per reactor (San Onofre 2 and 3 share a
# name and a page, with a row each).
#   Name | Acronym | Docket Number | License Number | ISFSI License & Type | Location
# Every row links to NRC's page for its site, which names the licensee.
class DataQuality::Plugins::NrcDecommissioning::List
  Row = Data.define(:name, :acronym, :nrc_docket, :license_number, :isfsi, :location, :page_url, :line) do
    def city = location[/\A(.+),\s*[A-Z]{2}\z/, 1]
    def state = location[/,\s*([A-Z]{2})\z/, 1]
  end
  HOST = "https://www.nrc.gov"

  # Returns [] when the table isn't there, e.g. after a site redesign.
  def self.rows(html)
    table = table_in(html) or return []
    table.css("tr").filter_map { |row| row_from(row) }
  end

  # The header and every row as plain text, cells separated by " | ":
  #   "Crystal River – Unit 3 | CR-3 | 05000302 | DPR-72 | 07201035*(GL) | Crystal River, FL"
  def self.lines(html)
    table = table_in(html) or return []
    table.css("tr").map { |row| line(row) }
  end

  def self.table_in(html)
    Nokogiri::HTML(html.to_s).css("table").find do |table|
      header = table.at_css("tr")&.text.to_s
      header.include?("Docket") && header.include?("ISFSI")
    end
  end
  private_class_method :table_in

  def self.line(row) = row.css("th, td").map { |cell| cell.text.squish }.join(" | ")
  private_class_method :line

  def self.row_from(row)
    cells = row.css("td")
    return if cells.size < 6

    docket = cells[2].text.squish
    name = cells[0].text.squish
    return if name.blank? || !docket.match?(/\A\d{8}\z/)

    href = cells[0].at_css("a")&.[]("href").to_s.strip
    # Only NRC's own pages: a link elsewhere has no licensee for us to read.
    page_url = href.start_with?("/") ? "#{HOST}#{href}" : (href if href.start_with?("#{HOST}/"))
    Row.new(name:, acronym: cells[1].text.squish, nrc_docket: docket, license_number: cells[3].text.squish,
      isfsi: cells[4].text.squish, location: cells[5].text.squish, page_url:, line: line(row))
  end
  private_class_method :row_from
end
