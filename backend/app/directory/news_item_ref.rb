# What Directory::Lookup returns for a news item (#137): plain values, not a
# model, for a company's or plant's "Latest".
Directory::NewsItemRef = Data.define(:id, :url, :title, :publisher, :published_on, :summary, :verification_status) do
  def self.from(item) = new(**item.slice(*members).symbolize_keys)
end
