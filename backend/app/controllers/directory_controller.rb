# The directory and search results: one page, one list (#40). Pressing Enter
# in any search field lands here with q set; a category pill sets category.
class DirectoryController < ApplicationController
  # Categories that became tags (#281). Their old addresses move for good.
  CATEGORY_TAGS = { "fusion" => "fusion" }.freeze

  def index
    if (tag = CATEGORY_TAGS[params[:category]])
      return redirect_to companies_url(params.permit(:q, :technology, :state, :sort).merge(tag:)), status: :moved_permanently
    end

    @listing = DirectoryListing.new(**params.permit(:category, :tag, :q, :technology, :state, :sort, :role).to_h.symbolize_keys)
    # The filter sheet's "Show N results" (#90) asks for the count only; it isn't a search.
    return render(json: { count: @listing.company_scope.count + @listing.plant_scope.count }) if request.format.json?

    @companies = @listing.companies.to_a
    @plants = @listing.plants.to_a
    @counts = DirectoryListing.category_counts
    @roles_by = @listing.roles_by(@companies)

    # A suggested search on the home page says so (from=suggestion).
    source = params[:from] == "suggestion" ? "suggestion" : "typed"
    track_search(@listing.query, results: @companies.size + @plants.size, source:) if @listing.searching?
  end
end
