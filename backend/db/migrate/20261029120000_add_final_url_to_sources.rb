# Enrich (#525): the address a page ended at after redirects, so its
# relative links are read against it ("/" to "/en/": "about" is
# "/en/about"). Null when the page didn't redirect. Additive.
class AddFinalUrlToSources < ActiveRecord::Migration[8.1]
  def change
    add_column :sources, :final_url, :string
  end
end
