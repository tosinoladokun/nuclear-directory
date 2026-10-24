# The directory and search results: one page, one list (#40). Pressing Enter
# in any search field lands here with q set; a category pill sets category.
class DirectoryController < ApplicationController
  # Categories that became tags (#281). Their old addresses move for good.
  CATEGORY_TAGS = { "fusion" => "fusion" }.freeze

  PAGE = 50

  def index
    if (tag = CATEGORY_TAGS[params[:category]])
      return redirect_to companies_url(params.permit(:q, :technology, :state, :sort).merge(tag:)), status: :moved_permanently
    end

    @listing = DirectoryListing.new(**params.permit(:category, :tag, :q, :technology, :state, :sort, :role).to_h.symbolize_keys)

    # The first PAGE rows of each list (companies, plants), then PAGE more per "Show more" (?shown=2 is two
    # pages' worth), so the page stays light as the directory grows. The
    # count stays the full one.
    @shown = params[:shown].to_i.clamp(1, 1000) * PAGE
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

    @companies = @listing.companies.limit(@shown).to_a
    @plants = @listing.plants.limit(@shown).to_a
    # A Show more request wants only the frame's rows (Turbo drops the rest), so the
    # category counts, the slowest part of the page, are skipped for it.
    @counts = DirectoryListing.category_counts unless turbo_frame_request?

    # A suggested search on the home page says so (from=suggestion).
    source = params[:from] == "suggestion" ? "suggestion" : "typed"
    # Show more (?shown=2) is the same search, expanded: not a new one.
    track_search(@listing.query, results: exact_total, source:) if @listing.searching? && params[:shown].blank?
  end
end
