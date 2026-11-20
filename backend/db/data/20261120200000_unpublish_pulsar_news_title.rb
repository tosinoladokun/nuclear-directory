# Data Quality, 20 Nov 2026 (social shadow review): news item 70, a NASA Fermi pulsar result, is not nuclear (the
# nuclear-only news rule, 29 Oct) and comes off. Its claim was approved in Today before Data Quality judged it, so
# there is nothing for Data Quality's endpoint to reject. Merging this PR is Tosin's approval.
#
# Replaces 20261120190000_unpublish_pulsar_news, which pinned the item's headline instead of its title and skipped.
# Pinned on its id and its exact title. Already off, or changed since (a person may have decided it): skipped and
# said, never a stopped deploy (#811).
class UnpublishPulsarNewsTitle < DeployData::Migration
  BY = "human:tosin"
  ID = 70
  TITLE = "NASA Science Data Powers New Method to Discover Hard-to-Find Pulsars".freeze
  REASON = "Not nuclear: a pulsar astrophysics result (Data Quality, 20 Nov)".freeze

  def up
    news = NewsItem.find_by(id: ID)
    return say("News item #{ID} is gone; nothing to do") unless news
    return say("News item #{ID} is now #{news.title.inspect}, not the pulsar item; left as it is") unless news.title == TITLE
    return say("News item #{ID} is already #{news.verification_status}") unless news.verification_status == "verified"

    result = DataQuality::Review.unpublish(type: "NewsItem", id: ID, by: BY, reason: REASON)
    return say("Taking off news item #{ID} failed, left as it is: #{Array(result.errors).join('; ')}") unless result.ok?

    say "Took off news item #{ID} (#{TITLE})"
  end
end
