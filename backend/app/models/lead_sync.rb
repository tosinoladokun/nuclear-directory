# Brings every source of leads (#484) into the Leads table. Each sighting has
# a stable key, so running it again only updates what changed:
# - searches that found nothing (#483), as typed, counted per search;
# - news (#137) about a company or plant the directory doesn't have;
# - trade-press items (#127), leads to a primary source;
# - Enrich findings (#479) naming a company it couldn't find;
# - DOE award recipients waiting for their night (#513's cap).
# It only adds and updates leads; a lead's status is the admin's.
class LeadSync
  def self.run = new.run

  def run
    counts = Hash.new(0)
    { "search" => searches, "news" => news, "trade_press" => trade_press, "enrich" => enrich, "awards" => awards }.each do |feed, sightings|
      sightings.each { |sighting| counts[feed] += 1 if Lead.sighted!(**sighting) }
    end
    counts
  end

  private
    def searches
      SearchGap.waiting.map do |gap|
        { name: gap.query, kind: "other", key: "search:#{gap.id}", label: "Search with no results", times: gap.searches_count,
          first: gap.first_searched_on, last: gap.last_searched_on }
      end
    end

    # Every name a news item gives that the directory doesn't have, even when
    # another name in it matched; keyed by the article and the name.
    def news
      Candidate.where(kind: "news_item", status: %w[new matched needs_review]).where("candidates.payload->>'lead' IS DISTINCT FROM 'true'")
        .flat_map do |claim|
        Array(claim.payload["about"]).filter_map do |entry|
          next unless entry.is_a?(Hash) && entry["name"].present?

          plant = entry["type"] == "facility"
          next if plant ? Directory::Lookup.facility(name: entry["name"]) : Directory::Lookup.organization(name: entry["name"])

          { name: entry["name"], kind: plant ? "plant" : "company", key: "news:#{claim.payload['url'] || claim.id}:#{Lead.normalize(entry['name'])}",
            label: "News: #{claim.payload['title']}", url: claim.payload["url"], first: claim.created_at.to_date }
        end
      end
    end

    def trade_press
      open_claims.where(kind: "news_item").where("candidates.payload->>'lead' = 'true'").map do |claim|
        { name: claim.payload["title"], kind: "other", key: "trade_press:#{claim.id}", label: "Trade press: #{claim.payload['publisher']}",
          url: claim.payload["url"], first: claim.created_at.to_date }
      end
    end

    def enrich
      open_claims.joins(:source).where(sources: { source_kind: "company_pages" }).flat_map do |claim|
        DataQuality::Review.open_company_ends(claim).map do |key, name|
          # By its page and the name, so a re-read page's new claim is the same sighting.
          { name:, kind: "company", key: "enrich:#{claim.source_id}:#{Lead.normalize(name)}", label: "Enrich: named on #{claim.source.domain}", url: claim.source.url,
            first: claim.created_at.to_date }
        end
      end
    end

    def awards
      Source.where(source_kind: "usaspending_doe_awards", extracted_sha256: nil).crawl_ok.where.not(content_text: [ nil, "" ]).filter_map do |source|
        name = CSV.parse(source.content_text, headers: true).first&.fetch("recipient_name", nil).presence or next
        { name:, kind: "company", key: "awards:#{source.id}", label: "DOE awards, waiting for its night", url: source.url,
          first: source.created_at.to_date }
      rescue CSV::MalformedCSVError
        nil
      end
    end

    def open_claims = Candidate.where(status: %w[new needs_review], subject_id: nil)
end
