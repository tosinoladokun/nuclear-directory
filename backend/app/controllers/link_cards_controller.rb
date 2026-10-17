# A page's link-preview image (#245). The address carries the card's digest
# (a hash of everything drawn), so it's cached for a year by browsers,
# Cloudflare and link previewers, and a page whose facts change gets a new
# address. An old digest moves to the current card; a hidden or unknown page
# is "Not found", as its page is. Drawn once per digest, then cached.
class LinkCardsController < ApplicationController
  def show
    # A category that became a tag page (#281) had its own card; its tag page
    # uses the default one, so an old image address moves there.
    if params[:kind] == "categories" && DirectoryController::CATEGORY_TAGS.key?(params[:key])
      return redirect_to(self.class.url_for_card(LinkCard.default, "default"), status: :moved_permanently)
    end

    card = find_card or raise ActiveRecord::RecordNotFound
    return redirect_to(self.class.url_for_card(card, params[:kind], params[:key]), status: :moved_permanently) if card.digest != params[:digest]

    png = Rails.cache.fetch([ "link_card", card.digest ]) { card.png }
    expires_in 1.year, public: true, immutable: true
    send_data png, type: "image/png", disposition: "inline"
  end

  # The path of a card, for a page's og:image. Built here rather than with the
  # route helpers, so a page drawn under other routes (tests) still has one.
  def self.url_for_card(card, kind, key = nil)
    [ "", "cards", kind, (ERB::Util.url_encode(key) if key), "#{card.digest}.png" ].compact.join("/")
  end

  private
    def find_card
      case params[:kind]
      when "default" then LinkCard.default
      when "plants" then (profile = PlantProfile.find(params[:key])) && LinkCard.for_plant(profile)
      when "companies" then (profile = CompanyProfile.find(params[:key])) && LinkCard.for_company(profile)
      when "categories"
        category = Category.find(params[:key]) or return
        LinkCard.for_category(category, DirectoryListing.category_counts.fetch(category.key))
      end
    end
end
