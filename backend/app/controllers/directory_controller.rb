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

    @listing = DirectoryListing.new(**params.permit(:category, :tag, :q, :technology, :state, :sort).to_h.symbolize_keys)
    # The filter sheet's "Show N results" (#90) asks for the count only; it isn't a search.
    return render(json: { count: @listing.company_scope.count + @listing.plant_scope.count }) if request.format.json?

    # The first PAGE rows of each list (companies, plants), then PAGE more per "Show more" (?shown=2 is two
    # pages' worth), so the page stays light as the directory grows. The
    # count stays the full one.
    @shown = params[:shown].to_i.clamp(1, 1000) * PAGE
    @companies_total, @plants_total = @listing.company_scope.count, @listing.plant_scope.count
    @companies = @listing.companies.limit(@shown).to_a
    @plants = @listing.plants.limit(@shown).to_a
    @counts = DirectoryListing.category_counts

    # A suggested search on the home page says so (from=suggestion).
    source = params[:from] == "suggestion" ? "suggestion" : "typed"
    track_search(@listing.query, results: @companies_total + @plants_total, source:) if @listing.searching?
  end
end
