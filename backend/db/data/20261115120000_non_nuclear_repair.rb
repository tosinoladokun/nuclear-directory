# PM and Data Quality, 15 Nov 2026: more items Data Quality had said no to that went live before #780. A NASA
# news item about Mars rocks comes off, and three DOE "funds" links to companies outside nuclear (Radiabeam,
# CPS Technologies, Phoenix Tailings) come off with their award terms and their quotes. Merging this PR is
# Tosin's approval.
#
# Pinned on the ids and values Data Quality read in production on 15 Nov: anything else stops the step;
# already off is skipped. The three companies stay pending, as they are.
class NonNuclearRepair < DeployData::Migration
  BY = "human:tosin"
  REASON = "Not nuclear"
  NEWS = { id: 37, url: "https://science.nasa.gov/blog/rubies-on-mars/" }.freeze
  # link id => its company (the "to" end), award term and the quote row it added
  LINKS = {
    229 => { company_id: 268, company: "Radiabeam Technologies", term_id: 173, evidence_id: 3703 },
    230 => { company_id: 269, company: "CPS Technologies", term_id: 174, evidence_id: 3704 },
    232 => { company_id: 271, company: "Phoenix Tailings", term_id: 176, evidence_id: 3706 }
  }.freeze
  FUNDER = "U.S. Department of Energy"

  def up
    take_off("NewsItem", NEWS[:id]) do
      news = NewsItem.find_by(id: NEWS[:id]) or raise "news item #{NEWS[:id]} is gone"
      raise "news item #{NEWS[:id]} is no longer at #{NEWS[:url]}: #{news.url}" unless news.url == NEWS[:url]
      news
    end

    LINKS.each do |id, pin|
      link = take_off("Relationship", id) do
        link = Relationship.find_by(id:) or raise "link #{id} is gone"
        ends = [ link.from_organization&.name, link.relationship_type, link.to_organization_id ]
        raise "link #{id} is no longer #{FUNDER} funds #{pin[:company]}: #{ends.inspect}" unless ends == [ FUNDER, "funds", pin[:company_id] ]
        link
      end
      take_off("DealTerm", pin[:term_id]) do
        term = DealTerm.find_by(id: pin[:term_id]) or raise "deal term #{pin[:term_id]} is gone"
        raise "deal term #{pin[:term_id]} is no longer on link #{id}" unless term.link_type == "Relationship" && term.link_id == link.id
        term
      end
      evidence = Evidence.find_by(id: pin[:evidence_id])
      next say("Quote #{pin[:evidence_id]} is already gone") if evidence.nil?
      raise "quote #{pin[:evidence_id]} is no longer on link #{id}" unless evidence.subject_type == "Relationship" && evidence.subject_id == id

      evidence.destroy!
      say "Removed quote #{pin[:evidence_id]} (#{FUNDER} funds #{pin[:company]})"
    end
  end

  private
    # Takes the record the block finds (and checks) off, as Tosin's decision; skipped when it's already off, and
    # stopped when someone decided it differently since 15 Nov (it must still be published).
    def take_off(type, id)
      record = yield
      return record.tap { say("#{type} #{id} is already off") } if record.verification_status == "unpublished"
      raise "#{type} #{id} is #{record.verification_status}, not verified as on 15 Nov" unless record.verification_status == "verified"

      result = DataQuality::Review.unpublish(type:, id:, by: BY, reason: "#{REASON}; #{reason}")
      raise "taking off #{type} #{id} failed: #{Array(result.errors).join('; ')}" unless result.ok?

      say "Took off #{type} #{id}"
      record
    end
end
