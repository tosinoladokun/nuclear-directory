# Instant results for the home and header search fields (#41): a Turbo Frame
# with the first few companies and plants and sites, grouped. Pressing Enter
# goes to the full results on the directory page instead, which is also
# where a search is counted (counting every keystroke's prefix would
# inflate the numbers).
class SearchController < ApplicationController
  MINIMUM_LENGTH = 2
  COMPANY_LIMIT = 5
  PLANT_LIMIT = 4

  def index
    listing = DirectoryListing.new(q: params[:q])
    @query = listing.query if listing.query.to_s.length >= MINIMUM_LENGTH

    if @query
      @companies = listing.companies.limit(COMPANY_LIMIT).to_a
      @plants = listing.plants.limit(PLANT_LIMIT).to_a
      # Nothing exact: close names ("brown ferry" finds Browns Ferry), said so (#431).
      if @companies.empty? && @plants.empty? && listing.fuzzy_possible?
        close = listing.fuzzy_copy
        @companies = close.companies.limit(COMPANY_LIMIT).to_a
        @plants = close.plants.limit(PLANT_LIMIT).to_a
        @fuzzy = @companies.any? || @plants.any?
      end
      # Each company's first category, for its square: one pass for the whole list.
      @categories = Bucket.firsts(@companies)
      @roles = OrganizationRole.published.where(organization_id: @companies.map(&:id)).includes(:role).group_by(&:organization_id)
    end

    @frame_id = frame_id
    render layout: false
  end

  private
    # Each search box has its own frame; Turbo names it in this header.
    def frame_id
      requested = request.headers["Turbo-Frame"].to_s
      requested.match?(/\A[a-z0-9-]+\z/) ? requested : "instant-results"
    end
end
