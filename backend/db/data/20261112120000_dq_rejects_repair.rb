# Data Quality, 12 Nov 2026: values it had said no to went live (its reject
# didn't stop a claim the verifier recommended; fixed in #780). Three wrong
# company values go back to what their sources say, and one news item that
# isn't about nuclear comes off. Merging this PR is Tosin's approval.
#
# Pinned: each record is changed only while it still has the wrong value read
# on 12 Nov; one already fixed is left and named; anything else stops the step.
class DqRejectsRepair < DeployData::Migration
  BY = "human:tosin"
  # id => [ what it says now, what it should say, why ] (ids from Data Quality)
  COMPANIES = {
    # The French parent (country FR), not its US arm Framatome Inc. in Lynchburg.
    13 => [ { hq_city: "Lynchburg", hq_state: "VA", country_code: "FR" }, { hq_city: "Courbevoie", hq_state: nil },
      "\"Framatome head office 1 Place Jean Millier – Tour Areva 92400 Courbevoie France\" (https://www.framatome.com/en/contact-us)" ],
    98 => [ { legal_name: "BWX Technologies. Inc." }, { legal_name: "BWX Technologies, Inc." },
      "\"provided by subsidiaries of BWX Technologies, Inc.\" (https://www.bwxt.com); the old value was a typo" ],
    96 => [ { legal_name: "Container Technologies Industries, Inc." }, { legal_name: "Container Technologies Industries, LLC" },
      "\"Container Technologies Industries, LLC (CTI Fab) is your trusted partner\" (https://containertechnologies.com)" ]
  }.freeze
  NEWS_ID = 18
  NEWS_TITLE = "Inside Vistra\u2019s 2026 Summer Internship Program"

  def up
    COMPANIES.each do |id, (wrong, right, why)|
      company = Organization.find_by(id:) or raise "company #{id} is gone"
      name = company.name
      next say("#{name}: already fixed") if right.all? { |field, value| company[field] == value }
      unless wrong.all? { |field, value| company[field] == value }
        raise "#{name} no longer has the value read on 12 Nov: #{wrong.keys.to_h { |field| [ field, company[field] ] }.inspect}"
      end

      result = Directory::FactWriter.write("organization", { id: company.id, **right },
        verification: { status: company.verification_status, by: BY, reason: "#{why}; #{reason}" }, protect_human_verified: false)
      raise "#{name}: #{result.errors.to_sentence}" unless result.ok?

      say "#{name}: #{right.map { |field, value| "#{field} #{value.inspect}" }.join(', ')}"
    end

    news = NewsItem.find_by(id: NEWS_ID) or raise "news item #{NEWS_ID} is gone"
    raise "news item #{NEWS_ID} is no longer #{NEWS_TITLE.inspect}: #{news.title.inspect}" unless news.title == NEWS_TITLE
    return say("News item #{NEWS_ID} is already off") if news.verification_status == "unpublished"

    result = DataQuality::Review.unpublish(type: "NewsItem", id: NEWS_ID, by: BY, reason: "Not nuclear (https://vistracorp.com/inside-vistras-2026-summer-internship-program/); #{reason}")
    raise "unpublishing news item #{NEWS_ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off news item #{NEWS_ID} (#{NEWS_TITLE})"
  end
end
