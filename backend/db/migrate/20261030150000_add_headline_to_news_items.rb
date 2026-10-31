# A short headline for "Latest" (PM, 30 Oct): a Federal Register title is a
# long docket string. 80 characters at most; nullable, shown in place of the
# title when present.
class AddHeadlineToNewsItems < ActiveRecord::Migration[8.1]
  def change
    add_column :news_items, :headline, :string
    add_check_constraint :news_items, "char_length(headline) <= 80", name: "news_items_headline_length"
  end
end
