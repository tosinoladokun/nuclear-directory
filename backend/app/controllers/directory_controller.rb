# The directory and search results: one page, one list (#40). Pressing Enter
# in any search field lands here with q set; a category pill sets category.
class DirectoryController < ApplicationController
  # Categories that became tags (#281). Their old addresses move for good.
  CATEGORY_TAGS = { "fusion" => "fusion" }.freeze

  PAGE = 24
  CACHED_PAGES = 3

  def index
    if (tag = CATEGORY_TAGS[params[:category]])
      return redirect_to companies_url(params.permit(:q, :technology, :state, :sort).merge(tag:)), status: :moved_permanently
    end

    # A tag we don't have (?tag=smr; SMR has no tag page by design) would
    # show every company: search for its words instead, as the home page's
    # "SMR" suggestion does.
    if params[:tag].present? && Tag.find(params[:tag]).nil?
      words = params[:tag].to_s.tr("-_", "  ").squish
      return redirect_to companies_url(params.permit(:technology, :state, :sort).merge(q: words.length <= 4 ? words.upcase : words)), status: :moved_permanently
    end

    @listing = DirectoryListing.new(**params.permit(*DirectoryListing::FILTERS).to_h.symbolize_keys)

    # The first PAGE rows of each list (companies, plants), then PAGE more per "Show more" (?shown=2 is two
    # pages' worth), so the page stays light as the directory grows. The
    # count stays the full one.
    @shown = params[:shown].to_i.clamp(1, 1000) * PAGE
    # A list that isn't a search is the same for everyone: the page builds it
    # once per data version (PageCacheHelper), so its queries run only then (PM, 3 Nov).
    # Up to CACHED_PAGES pages of rows: ?shown=4..1000 would each be a full list under its own key (Infra).
    if !@listing.searching? && request.format.html? && !turbo_frame_request? && @shown <= CACHED_PAGES * PAGE
      listing, shown = @listing, @shown
      # The key is built from the listing's accepted filters (DirectoryListing#cache_key_parts), so only values it accepted
      # count (a junk parameter is dropped) and a new filter can't be left out.
      @page_key = [ "companies", *listing.cache_key_parts, shown ]
      @load_list = -> { self.class.list(listing, shown, counts: true) }
      return
    end

    @companies_total, @plants_total = @listing.company_scope.count, @listing.plant_scope.count
    # A search with no exact match falls back to close names ("brown ferry" finds
    # Browns Ferry), and the page says so (#431).
    exact_total = @companies_total + @plants_total
    if @listing.searching? && exact_total.zero? && @listing.fuzzy_possible?
      close = @listing.fuzzy_copy
      close_companies, close_plants = close.company_scope.count, close.plant_scope.count
      if (close_companies + close_plants).positive?
        @listing, @fuzzy = close, true
        @companies_total, @plants_total = close_companies, close_plants
      end
    end
    # The filter sheet's "Show N results" (#90) asks for the count only; it isn't a
    # search. It counts what the page shows, close names included.
    return render(json: { count: @companies_total + @plants_total }) if request.format.json?

    list = self.class.list(@listing, @shown, counts: !turbo_frame_request?, totals: [ @companies_total, @plants_total ])
    @companies, @plants, @counts, @all_count, @short = list.values_at(:companies, :plants, :counts, :all_count, :short)

    # Show more (?shown=2) is the same search, expanded: not a new one.
    # A gap is a search of the whole directory finding nothing: a category,
    # tag or filter narrowing it to nothing isn't one. What the page showed
    # decides it, so a typo the close-match fallback answers (#496) is a hit
    # (closing a gap it had), while analytics keep the exact count.
    unfiltered = !@listing.filtered? && @listing.category.nil? && @listing.tag.nil?
    track_search(@listing.query, results: exact_total, gap: (params[:q].to_s if unfiltered),
      shown: @companies_total + @plants_total) if @listing.searching? && params[:shown].blank?
  end

  # What the list shows. A Show more request wants only the frame's rows (Turbo drops the rest), so the
  # category counts, the slowest part of the page, are skipped for it (counts: false).
  def self.list(listing, shown, counts:, totals: nil)
    companies = listing.companies.limit(shown).to_a
    companies_total, plants_total = totals || [ listing.company_scope.count, listing.plant_scope.count ]
    {
      companies:, plants: listing.plants.limit(shown).to_a, companies_total:, plants_total:,
      counts: (DirectoryListing.category_counts if counts), all_count: (DirectoryListing.new.company_scope.count if counts),
      # The middle column of each company row, for the whole list in one go (#560).
      short: ShortDescription.for(companies, category: listing.category)
    }
  end
end
