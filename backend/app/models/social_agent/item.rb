# What one post is about (#769): a published fact, with everything the draft may say, the source it rests on,
# and the page it links to.
SocialAgent::Item = Data.define(:subject, :kind, :facts, :source_url, :source_quote, :path, :organization_ids) do
  # The words a post may use: its facts, the source's own words and the names it's about.
  def source_text = [ *facts.values, source_quote ].compact.join("\n")
end
