# A company's page (#42): only verified facts, each with its sources.
# A company's old address (renamed, or merged into another) moves to its
# current page (#143). Unknown or unverified companies get "Page not found".
class CompaniesController < ApplicationController
  def show
    # The profile is built only when the page isn't cached (PageCacheHelper).
    if (@organization = Organization.published.find_by(slug: params[:slug]))
      organization = @organization
      @load_profile = -> { CompanyProfile.new(organization) }
      track_company_viewed(organization.slug)
      return
    end

    # Only to a company the site shows; a hidden one stays "Page not found".
    current = Organization.find_by_former_slug(params[:slug])
    raise ActiveRecord::RecordNotFound unless current && CompanyProfile.find(current.slug)

    redirect_to company_path(slug: current.slug), status: :moved_permanently
  end
end
