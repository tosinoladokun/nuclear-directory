# What one post is about (#769): a published fact, with everything the draft may say, the source it rests on,
# and the page it links to.
# page_text: the source page's own words around the item (SocialAgent.prepare), read by the writer and the checks.
SocialAgent::Item = Data.define(:subject, :kind, :facts, :source_url, :source_quote, :path, :organization_ids, :page_text) do
  def initialize(page_text: nil, **rest) = super(page_text:, **rest)

  # The words a post may use: its facts, the source's own words (its page's too) and the names it's about.
  def source_text = [ *facts.values, source_quote, page_text ].compact.join("\n")

  # The item's own words, without the page around it (a page's menus and other stories aren't the item).
  def own_text = [ *facts.values, source_quote ].compact.join("\n")
end
