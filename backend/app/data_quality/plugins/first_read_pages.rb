# Pages a planned source will read, captured before its reader is written
# (PM, 26 Oct): NRC's press releases (NRC refuses the workstation) and
# DIU's Latest page (its items are drawn by script). The nightly crawl
# stores each page as it comes, through the shared Fetcher, so the reader
# can be built against the real page from production. It proposes nothing:
# extract returns no claims, and nothing here is cited. A block is recorded.
class DataQuality::Plugins::FirstReadPages < DataQuality::Plugin
  PAGES = {
    "https://www.nrc.gov/reading-rm/doc-collections/news/" => "NRC news releases (first read)",
    "https://www.diu.mil/latest" => "DIU Latest (first read)"
  }.freeze

  def initialize(fetcher: DataQuality::Fetcher.new, pages: PAGES)
    @fetcher = fetcher
    @pages = pages
  end

  def crawl(_run)
    @pages.to_h do |url, title|
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = title
      end
      [ title, DataQuality::Snapshot.take(source, fetcher: @fetcher).to_s ]
    end
  end

  # Captured only: no claims until a reader is built from the stored page.
  def extract(_source, _run) = []

  def max_dropped_share(_source) = 0.0
end
