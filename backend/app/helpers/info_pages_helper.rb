# The info pages as one About set (#660): its menu, and the footer's live counts.
module InfoPagesHelper
  # [label, key, path], in the menu's order.
  def info_pages = [ [ "About", :about, about_path ], [ "Our data", :data, data_path ], [ "Our crawler", :bot, bot_path ],
                     [ "Privacy", :privacy, privacy_path ], [ "Disclaimer", :disclaimer, disclaimer_path ] ]

  # "130 companies · 62 plants and sites" for the footer, live and cached for an hour (it is on every page).
  def footer_counts
    companies, plants = Rails.cache.fetch("footer/counts", expires_in: 1.hour) do
      [ DirectoryListing.new.company_scope.count, DirectoryListing.new(category: "plants").plant_scope.count ]
    end
    "#{number_with_delimiter(companies)} #{"company".pluralize(companies).sub("companys", "companies")} · #{number_with_delimiter(plants)} #{plants == 1 ? "plant or site" : "plants and sites"}"
  end
end
