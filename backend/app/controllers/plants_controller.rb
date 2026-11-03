# A power plant's page (#43): a public site with its verified units and the
# companies linked to them. A unit's address goes to its site's page, at the
# unit's row. A plant's old address (it was renamed) moves to its current
# one (#143). Unknown or hidden plants get "Page not found".
class PlantsController < ApplicationController
  def show
    # Only a unit the site's page actually lists (verified and sourced).
    unit = Facility.published.where.not(parent_id: nil).find_by(slug: params[:slug])
    if unit && (site = PlantProfile.find(unit.parent.slug)) && site.units.include?(unit)
      return redirect_to plant_path(slug: site.slug, anchor: "unit-#{unit.slug}"), status: :moved_permanently
    end

    # The profile is built only when the page isn't cached (PageCacheHelper).
    if (@site = Facility.published.where(parent_id: nil).find_by(slug: params[:slug]))
      site = @site
      @load_profile = -> { PlantProfile.new(site) }
      track_power_plant_viewed(site.slug)
      return
    end

    # Only to a plant the site shows; a hidden one stays "Page not found".
    current = Facility.find_by_former_slug(params[:slug])
    raise ActiveRecord::RecordNotFound unless current && Facility.published.exists?(id: current.id)

    redirect_to plant_path(slug: current.slug), status: :moved_permanently
  end
end
