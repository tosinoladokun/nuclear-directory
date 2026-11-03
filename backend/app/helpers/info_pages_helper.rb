# The info pages as one About set (#660): its menu.
module InfoPagesHelper
  # [label, key, path], in the menu's order.
  def info_pages = [ [ "About", :about, about_path ], [ "Our data", :data, data_path ], [ "Our crawler", :bot, bot_path ],
                     [ "Privacy", :privacy, privacy_path ], [ "Disclaimer", :disclaimer, disclaimer_path ] ]
end
