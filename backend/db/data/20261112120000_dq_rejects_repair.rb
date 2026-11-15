# Data Quality, 12 Nov 2026: values it had said no to went live (its reject
# didn't stop a claim the verifier recommended; fixed in #780). Three wrong
# company values go back to what their sources say, and one news item that
# isn't about nuclear comes off. Merging this PR is Tosin's approval.
#
# Pinned: each record is changed only while it still has the wrong value read
# on 12 Nov; one already fixed is left and named; anything else stops the step.
class DqRejectsRepair < DeployData::Migration
  BY = "human:tosin"
  # id => what it says now (every pinned field), what it should say, and the source and quote that say so (ids, values
  # and quotes from Data Quality, 12 Nov)
  COMPANIES = {
    # The French parent (country FR), not its US arm Framatome Inc. in Lynchburg.
    13 => { wrong: { hq_city: "Lynchburg", hq_state: "VA", country_code: "FR" }, right: { hq_city: "Courbevoie", hq_state: nil },
            url: "https://www.framatome.com/en/contact-us", quote: "Framatome head office 1 Place Jean Millier \u2013 Tour Areva 92400 Courbevoie France",
            fields: %w[hq_city country_code] },
    98 => { wrong: { legal_name: "BWX Technologies. Inc." }, right: { legal_name: "BWX Technologies, Inc." },
            url: "https://www.bwxt.com", quote: "The products and services described herein are provided by subsidiaries of BWX Technologies, Inc.",
            fields: %w[legal_name] },
    96 => { wrong: { legal_name: "Container Technologies Industries, Inc." }, right: { legal_name: "Container Technologies Industries, LLC" },
            url: "https://containertechnologies.com",
            quote: "Container Technologies Industries, LLC (CTI Fab) is your trusted partner for superior quality metal fabrication services.",
            fields: %w[legal_name] }
  }.freeze
  NEWS_ID = 18
  NEWS_TITLE = "Inside Vistra\u2019s 2026 Summer Internship Program"
  NEWS_URL = "https://vistracorp.com/inside-vistras-2026-summer-internship-program/"

  def up
    COMPANIES.each do |id, fix|
      company = Organization.find_by(id:) or raise "company #{id} is gone"
      name = company.name
      # Fixed means the new values and every pinned field it keeps (Framatome's country) are as expected.
      kept = fix[:wrong].except(*fix[:right].keys)
      next say("#{name}: already fixed") if fix[:right].merge(kept).all? { |field, value| company[field] == value }
      unless fix[:wrong].all? { |field, value| company[field] == value }
        raise "#{name} no longer has the value read on 12 Nov: #{fix[:wrong].keys.to_h { |field| [ field, company[field] ] }.inspect}"
      end

      wrong_rows = wrong_evidence(company, fix)
      source = DataQuality::Sources.find_or_create(url: fix[:url])
      raise "#{name}: #{source.errors.to_sentence}" unless source.ref

      result = Directory::FactWriter.write("organization", { id: company.id, **fix[:right] },
        evidence: [ { source_id: source.ref.id, quote: fix[:quote], found_by: "human", confidence: 1, fields: fix[:fields] } ],
        verification: { status: company.verification_status, by: BY, reason: "#{fix[:url]}; #{reason}" }, protect_human_verified: false)
      raise "#{name}: #{result.errors.to_sentence}" unless result.ok?

      wrong_rows.each(&:destroy!)
      say "#{name}: #{fix[:right].map { |field, value| "#{field} #{value.inspect}" }.join(', ')} (#{fix[:url]}); " \
        "removed #{wrong_rows.size} quote(s) for the old value: #{wrong_rows.map { |row| row.quote.truncate(60).inspect }.join(', ')}"
    end

    news = NewsItem.find_by(id: NEWS_ID) or raise "news item #{NEWS_ID} is gone"
    unless news.title == NEWS_TITLE && news.url == NEWS_URL
      raise "news item #{NEWS_ID} is no longer #{NEWS_TITLE.inspect} at #{NEWS_URL}: #{news.title.inspect} at #{news.url}"
    end
    return say("News item #{NEWS_ID} is already off") if news.verification_status == "unpublished"
    raise "news item #{NEWS_ID} is #{news.verification_status}, not verified as on 12 Nov" unless news.verification_status == "verified"

    result = DataQuality::Review.unpublish(type: "NewsItem", id: NEWS_ID, by: BY, reason: "Not nuclear (#{NEWS_URL}); #{reason}")
    raise "unpublishing news item #{NEWS_ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off news item #{NEWS_ID} (#{NEWS_TITLE})"
  end

  private
    # The quotes the wrongly approved claims added: evidence on this company from the source and quote of a merged
    # claim Data Quality said no to, stating an old value. Stops when there's no such claim (nothing to say which).
    def wrong_evidence(company, fix)
      claims = Candidate.where(subject_type: "Organization", subject_id: company.id, status: "merged", dq_recommendation: "reject").to_a
        .select { |claim| fix[:wrong].slice(*fix[:right].keys).any? { |field, value| claim.payload.to_h[field.to_s] == value } }
      raise "#{company.name}: no merged claim Data Quality said no to states the old value" if claims.empty?

      rows = claims.flat_map { |claim| Evidence.where(subject: company, source_id: claim.source_id, quote: claim.quote).to_a }.uniq
      raise "#{company.name}: the old value's quote isn't on the company" if rows.empty?

      rows
    end
end
