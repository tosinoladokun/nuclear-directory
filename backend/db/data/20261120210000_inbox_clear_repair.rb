# Data Quality, 20 Nov 2026 (after the inbox clear, which approved claims Data Quality had not judged yet):
# - News item 69 (NANO Nuclear and SJ Group): its headline and summary said "collaboration"; the release says a signed
#   non-binding MOU with Surbana Jurong Infrastructure Pte. Ltd., an affiliate of SJ Group. Reworded as the release does.
# - News item 68 (a webcast notice) is not industry news and comes off.
# - News item 34 (Paducah FEIS, from GLE's own PDF) duplicates item 19 (the same environmental impact statement from the
#   Federal Register, NRC's own notice): the primary source stays, the duplicate comes off.
# - Lithios (company 344, pending) is a lithium-extraction startup, not nuclear: rejected; the ARPA-E funds link to it
#   (323) and its award term (262) come off, with the link's quote.
# - Moltex Energy (company 291) was published with the HQ of its US office (Wilmington, DE) while its legal name is
#   the parent's (Moltex Energy Limited): no source states the parent's headquarters, so the mixed HQ is cleared
#   until one does (the Wilmington address is the US office on Moltex's own contact page, not a headquarters).
#
# Merging this PR is Tosin's approval. Pinned on the ids and values Data Quality read in production on 20 Nov: a
# record that is not as read (changed, decided, or already done) is skipped and said, never a stopped deploy; a real
# failure raises, so the deploy records it, alerts, and tries the step again.
class InboxClearRepair < DeployData::Migration
  BY = "human:tosin"

  NANO_SJ = {
    id: 69,
    url: "https://nanonuclearenergy.com/nano-nuclear-energy-and-sj-group-establish-collaboration-to-advance-knowledge-exchange-and-capability-building-in-advanced-nuclear-energy-across-southeast-asia/",
    was: "NANO Nuclear and SJ Group establish Southeast Asia collaboration",
    headline: "NANO Nuclear signs non-binding MOU with Surbana Jurong, an SJ Group affiliate",
    summary: "NANO Nuclear Energy signed a non-binding memorandum of understanding with Surbana Jurong Infrastructure Pte. Ltd., an " \
      "affiliate of SJ Group, to advance knowledge exchange and capability building in advanced nuclear energy and to explore " \
      "potential applications in Southeast Asia."
  }.freeze
  WEBCAST = { id: 68, url: "https://nanonuclearenergy.com/nano-nuclear-to-hold-fourth-quarter-business-update-webcast-on-november-30-2026/" }.freeze
  PADUCAH_DUPLICATE = { id: 34, url: "https://www.gle-us.com/wp-content/uploads/2026/10/NRC-Issues-GLE-FEIS.pdf", keep_id: 19 }.freeze
  LITHIOS = { company_id: 344, name: "Lithios", link_id: 323, funder_id: 238, term_id: 262, amount: 19_999_250, evidence_id: 4486, evidence_source_id: 2129,
    evidence_quote: "Project: NEXUS: Next-Generation EXtraction of Untapped Lithium Sources | Organization: Lithios | Award: $19,999,250 | Program: SCALEUP Ready | Status: Active | Location: Medford, MA | Released: Apr 06 2026 | Area: nuclear fission | Funder: Advanced Research Projects Agency-Energy (ARPA-E)" }.freeze
  MOLTEX = { id: 291, name: "Moltex Energy", city: "Wilmington", state: "DE" }.freeze
  # Each record was last decided before this read (the inbox clear ran until 20:18 UTC).
  READ_AT = Time.utc(2026, 11, 20, 21)

  def up
    reword_nano_sj
    take_off_webcast
    take_off_paducah_duplicate
    reject_lithios
    clear_moltex_hq
  end

  private
    def reword_nano_sj
      news = NewsItem.find_by(id: NANO_SJ[:id]) or return say("News item #{NANO_SJ[:id]} is gone; nothing to do")
      return say("News item #{news.id} is #{news.verification_status}, not verified; left as it is") unless news.verification_status == "verified"
      return say("News item #{news.id} is not the NANO and SJ Group item (#{news.url}); left as it is") unless news.url == NANO_SJ[:url]
      return say("News item #{news.id} already says #{news.headline.inspect}") if news.headline == NANO_SJ[:headline]
      return say("News item #{news.id} is now #{news.headline.inspect}, not as read; left as it is") unless news.headline == NANO_SJ[:was]
      return say("News item #{news.id} was decided again on #{news.verified_at}; left as it is") if decided_since_read?(news)

      result = Directory::FactWriter.write("news_item", { id: news.id, headline: NANO_SJ[:headline], summary: NANO_SJ[:summary] },
        verification: { status: "verified", by: BY, reason: "the release says a non-binding MOU with Surbana Jurong Infrastructure, an SJ Group affiliate; #{reason}" },
        protect_human_verified: false)
      raise "news item #{news.id}: #{result.errors.to_sentence}" unless result.ok?

      say "News item #{news.id}: headline and summary now state the non-binding MOU"
    end

    def take_off_webcast
      news = NewsItem.find_by(id: WEBCAST[:id]) or return say("News item #{WEBCAST[:id]} is gone; nothing to do")
      take_off("NewsItem", news, ok: news.url == WEBCAST[:url], what: "the webcast notice", why: "Not industry news: a company event notice")
    end

    def take_off_paducah_duplicate
      news = NewsItem.find_by(id: PADUCAH_DUPLICATE[:id]) or return say("News item #{PADUCAH_DUPLICATE[:id]} is gone; nothing to do")
      kept = NewsItem.find_by(id: PADUCAH_DUPLICATE[:keep_id])
      return say("News item #{news.id}: its primary twin (#{PADUCAH_DUPLICATE[:keep_id]}) is not verified; left as it is") unless kept&.verification_status == "verified" || news.verification_status != "verified"

      take_off("NewsItem", news, ok: news.url == PADUCAH_DUPLICATE[:url], what: "the Paducah item from GLE's own PDF",
        why: "Duplicate of news item #{PADUCAH_DUPLICATE[:keep_id]} (the same statement from the Federal Register, NRC's own notice)")
    end

    def reject_lithios
      company = Organization.find_by(id: LITHIOS[:company_id])
      if company.nil? || company.name != LITHIOS[:name]
        say("Company #{LITHIOS[:company_id]} is not #{LITHIOS[:name]}; Lithios left as it is")
      elsif company.verification_status == "rejected"
        say("Company #{company.id} is already rejected")
      elsif company.verification_status != "pending"
        say("Company #{company.id} is #{company.verification_status}, not pending; left as it is")
      else
        result = DataQuality::Review.reject_fact(type: "Organization", id: company.id, by: BY, reason: "Not nuclear: a lithium-extraction startup; #{reason}")
        raise "rejecting company #{company.id} failed: #{Array(result.errors).join('; ')}" unless result.ok?

        say "Rejected company #{company.id} (#{LITHIOS[:name]})"
      end

      link = Relationship.find_by(id: LITHIOS[:link_id])
      ends = link && [ link.from_organization_id, link.relationship_type, link.to_organization_id ]
      link_ok = ends == [ LITHIOS[:funder_id], "funds", LITHIOS[:company_id] ]
      take_off("Relationship", link, ok: link_ok, what: "the ARPA-E link to Lithios", why: "Not nuclear: a lithium-extraction award")
      # Its term and quote only go with the link this step pinned, once it is off; a link that changed, or was
      # decided again since the read, keeps them (Copilot).
      return say("The Lithios link is not as pinned and off; its award term and quote are left as they are") unless link_ok && link.reload.verification_status == "unpublished"

      term = DealTerm.find_by(id: LITHIOS[:term_id])
      term_ok = term && term.link_type == "Relationship" && term.link_id == LITHIOS[:link_id] && term.amount_usd.to_i == LITHIOS[:amount]
      take_off("DealTerm", term, ok: term_ok, what: "its award term", why: "Not nuclear: a lithium-extraction award")

      evidence = Evidence.find_by(id: LITHIOS[:evidence_id])
      return say("Quote #{LITHIOS[:evidence_id]} is already gone") if evidence.nil?
      pinned = evidence.subject_type == "Relationship" && evidence.subject_id == LITHIOS[:link_id] &&
        evidence.source_id == LITHIOS[:evidence_source_id] && evidence.quote == LITHIOS[:evidence_quote]
      return say("Quote #{evidence.id} is not the one read on 20 Nov; left as it is") unless pinned

      evidence.destroy!
      say "Removed quote #{evidence.id} (the Lithios link)"
    end

    def clear_moltex_hq
      company = Organization.find_by(id: MOLTEX[:id]) or return say("Company #{MOLTEX[:id]} is gone; nothing to do")
      return say("Company #{company.id} has no HQ city; nothing to clear") if company.hq_city.blank? && company.hq_state.blank?
      unless company.name == MOLTEX[:name] && company.hq_city == MOLTEX[:city] && company.hq_state == MOLTEX[:state]
        return say("Company #{company.id} is now #{company.name.inspect}, #{company.hq_city.inspect}, #{company.hq_state.inspect}; left as it is")
      end
      return say("Company #{company.id} was decided again on #{company.verified_at}; left as it is") if decided_since_read?(company)

      result = Directory::FactWriter.write("organization", { id: company.id, hq_city: nil, hq_state: nil },
        verification: { status: company.verification_status, by: BY, reason: "Wilmington is the US office, not the headquarters of the parent (Moltex Energy Limited); #{reason}" },
        protect_human_verified: false)
      raise "company #{company.id}: #{result.errors.to_sentence}" unless result.ok?

      say "Company #{company.id}: the mixed HQ (Wilmington, DE) cleared"
    end

    def take_off(type, record, ok:, what:, why:)
      return say("#{upcase_first(what)} is gone; nothing to do") if record.nil?
      return say("#{upcase_first(what)} is already #{record.verification_status}") if record.verification_status == "unpublished"
      return say("#{upcase_first(what)} is not as read; left as it is") unless ok
      return say("#{upcase_first(what)} is #{record.verification_status}, not verified; left as it is") unless record.verification_status == "verified"
      return say("#{upcase_first(what)} was decided again on #{record.verified_at}; left as it is") if decided_since_read?(record)

      result = DataQuality::Review.unpublish(type:, id: record.id, by: BY, reason: "#{why}; #{reason}")
      raise "taking off #{what} failed: #{Array(result.errors).join('; ')}" unless result.ok?

      say "Took off #{what}"
    end

    def upcase_first(text) = text.sub(/\A./, &:upcase)

    # Decided again after the read: a later verified_at, or any later verification event (a same-reviewer edit keeps
    # verified_at but records an event; Copilot).
    def decided_since_read?(record)
      return true if record.verified_at.nil? || record.verified_at >= READ_AT

      VerificationEvent.where(subject: record).where(created_at: READ_AT..).exists?
    end
end
