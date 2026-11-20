# Data Quality, 20 Nov 2026 (social shadow review): news item 70, a NASA Fermi pulsar result, is not nuclear (the
# nuclear-only news rule, 29 Oct) and comes off. It has no claim Data Quality's endpoint could reject. Merging this
# PR is Tosin's approval.
#
# Pinned on its id and title. Already off, rejected, or changed since (a person may have decided it): skipped and
# said, never a stopped deploy (#811).
class UnpublishPulsarNews < DeployData::Migration
  BY = "human:tosin"
  ID = 70
  TITLE = "NASA Fermi data helps team develop faster pulsar search method".freeze
  REASON = "Not nuclear: a pulsar astrophysics result (Data Quality, 20 Nov)".freeze

  def up
    news = NewsItem.find_by(id: ID)
    return say("News item #{ID} is gone; nothing to do") unless news
    return say("News item #{ID} is now #{news.title.inspect}, not the pulsar item; left as it is") unless news.title == TITLE
    return say("News item #{ID} is already #{news.verification_status}") unless news.verification_status == "verified"

    result = DataQuality::Review.unpublish(type: "NewsItem", id: ID, by: BY, reason: REASON)
    raise "taking off news item #{ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off news item #{ID} (#{TITLE})"
  end
end
