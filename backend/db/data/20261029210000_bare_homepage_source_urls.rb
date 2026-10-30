# One address per bare homepage (#670): a Source stored as
# "https://www.mit.edu/" takes "https://www.mit.edu", the form the model now
# normalises to, so a lookup finds it and nothing makes a twin. Runs after
# MergeSlashDuplicateSources (#669), which merged every pair; a slash row
# whose twin exists all the same is left for a person and named. Only
# addresses and keys change, never a decision. Merging this PR is Tosin's
# approval.
class BareHomepageSourceUrls < DeployData::Migration
  BY = "human:tosin"
  # A bare homepage with its slash, as Source.bare_homepage reads it (any
  # case of scheme and host; no path, query or fragment).
  BARE_SLASH_SQL = '^https?://[^/?#[:space:]]+/$'
  # A page key on a bare homepage: "page:https://acme.com/#series b 1.0".
  # The part after the "#" holds no other "#": one that does is the key of a
  # page with a fragment ("page:https://acme.com/#investors#series b"),
  # whose address the model keeps, so its key stays too.
  OLD_KEY = %r{\Apage:(https?://[^/?#\s]+)/#([^#]*)\z}i
  OLD_KEY_SQL = '^page:https?://[^/?#[:space:]]+/#[^#]*$'

  def up
    renamed = 0
    Source.where("url ~* ?", BARE_SLASH_SQL).find_each do |source|
      bare = source.url.chomp("/")
      if Source.where.not(id: source.id).where("LOWER(url) = LOWER(?)", bare).exists?
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
    def new_key(key) = key.sub(OLD_KEY, 'page:\1#\2')

    # Enrich keys a page's deal terms by the page's address
    # ("page:https://acme.com/#series b …"). With the address normalised, a
    # re-read keys them "page:https://acme.com#…", so the stored keys follow,
    # or the next read would add each term again. A term whose new key is
    # already taken is left and named, and so are its claims.
    def rekey_page_terms
      rekeyed = 0
      skipped = []
      DealTerm.where("external_id ~* ?", OLD_KEY_SQL).find_each do |term|
        key = new_key(term.external_id)
        if DealTerm.where.not(id: term.id).exists?(link_type: term.link_type, link_id: term.link_id, term_type: term.term_type, external_id: key)
          say "Deal term #{term.id}: left as it is; #{key} exists too"
          skipped << term.id
          next
        end

        term.update_columns(external_id: key, updated_at: Time.current)
        rekeyed += 1
      end
      rekey_claims(rekeyed, skipped)
    end

    # Every claim's payload key, whatever its status (a rejected one can be
    # reopened and matched again), except claims on a term left as it is.
    # Only the payload changes; no claim's decision does.
    def rekey_claims(rekeyed, skipped)
      claims = Candidate.where("payload->>'external_id' ~* ?", OLD_KEY_SQL)
      left = claims.where(subject_type: "DealTerm", subject_id: skipped)
      left.find_each { |claim| say "Claim #{claim.id}: key left as it is, with its deal term #{claim.subject_id}" }
      changed = 0
      claims.where.not(id: left.select(:id)).find_each do |claim|
        claim.update_columns(payload: claim.payload.merge("external_id" => new_key(claim.payload["external_id"])), updated_at: Time.current)
        changed += 1
      end
      say "Re-keyed #{rekeyed} deal terms and #{changed} claims to the page's address without the slash"
    end
end
