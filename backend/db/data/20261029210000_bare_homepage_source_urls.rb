# One address per bare homepage (#670): a Source stored as
# "https://www.mit.edu/" takes "https://www.mit.edu", the form the model now
# normalises to, so a lookup finds it and nothing makes a twin. Runs after
# MergeSlashDuplicateSources (#669), which merged every pair; a slash row
# whose twin exists all the same is left for a person and named. Only the
# address changes. Merging this PR is Tosin's approval.
class BareHomepageSourceUrls < DeployData::Migration
  BY = "human:tosin"
  OLD_KEY = %r{\Apage:(https?://[^/?#\s]+)/#}

  def up
    renamed = 0
    Source.where("url ~ ?", '^https?://[^/?#[:space:]]+/$').find_each do |source|
      bare = source.url.chomp("/")
      if Source.where.not(id: source.id).exists?(url: bare)
        say "#{source.url}: left as it is; #{bare} exists too (merge it by hand)"
        next
      end

      source.update_columns(url: bare, updated_at: Time.current)
      renamed += 1
    end
    say "Gave #{renamed} homepage sources their address without the trailing slash"
    rekey_page_terms
  end

  private
    # Enrich keys a page's deal terms by the page's address
    # ("page:https://acme.com/#series b …"). With the address normalised, a
    # re-read keys them "page:https://acme.com#…", so the stored keys follow,
    # or the next read would add each term again. A key the slash-less form
    # already holds is left and named.

    def rekey_page_terms
      rekeyed = 0
      DealTerm.where("external_id ~ ?", '^page:https?://[^/?#[:space:]]+/#').find_each do |term|
        key = term.external_id.sub(OLD_KEY, 'page:\\1#')
        if DealTerm.where.not(id: term.id).exists?(link_type: term.link_type, link_id: term.link_id, term_type: term.term_type, external_id: key)
          say "Deal term #{term.id}: left as it is; #{key} exists too"
          next
        end

        term.update_columns(external_id: key, updated_at: Time.current)
        rekeyed += 1
      end
      claims = Candidate.where(status: %w[new matched needs_review]).where("payload->>'external_id' ~ ?", '^page:https?://[^/?#[:space:]]+/#')
      reclaimed = claims.count
      claims.find_each do |claim|
        claim.update_columns(payload: claim.payload.merge("external_id" => claim.payload["external_id"].sub(OLD_KEY, 'page:\\1#')),
          updated_at: Time.current)
      end
      say "Re-keyed #{rekeyed} deal terms and #{reclaimed} open claims to the page's address without the slash"
    end
end
