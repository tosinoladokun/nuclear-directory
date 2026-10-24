require "csv"

# U.S. Department of Energy awards from USAspending.gov (#123), the first
# deals and funding source (M5). Proposes each recipient company and one
# "U.S. Department of Energy funds <company>" link per company, whose
# description sums up its awards; each award is cited on the recipient's
# USAspending page, where it's listed.
#
# Crawl asks USAspending's award search API (a JSON POST, through the
# shared Fetcher's rules) for three searches, businesses only, $1M or more,
# with activity in the last five years:
# - nuclear energy R&D grants and cooperative agreements (Assistance
#   Listing 81.121, which includes the ARDP demonstrations)
# - DOE contracts mentioning HALEU or nuclear fuel
# - fusion grants under the Office of Science (81.049, "fusion"), for
#   fusion energy work only (FUSION_ENERGY)
# - small-business (SBIR/STTR-sized) Office of Science grants from $100,000,
#   for nuclear energy work only (NUCLEAR_ENERGY, #125)
# The API's own fetch state (today's fetch, a block) is kept on an index
# source that's never extracted. Awards are stored as CSV rows, one source
# per recipient, with every field a later award table needs (#256): award
# ID, amount, dates, Assistance Listing, award type and its page.
#
# Extract reads those rows; no model is asked. Match, verify and a human's
# approval are shared, as for every source.
class DataQuality::Plugins::UsaspendingDoeAwards < DataQuality::Plugin
  API_URL = "https://api.usaspending.gov/api/v2/search/spending_by_award/"
  INDEX_SOURCE_KIND = "usaspending_api"
  FUNDER = "U.S. Department of Energy"
  YEARS = 5
  MIN_AMOUNT = 1_000_000
  PAGE_SIZE = 100
  MAX_PAGES = 10 # per search: 1,000 awards, far more than these searches hold
  ASSISTANCE = %w[02 03 04 05].freeze # grants and cooperative agreements
  CONTRACTS = %w[A B C D].freeze
  SEARCHES = {
    "nuclear_energy_rd" => { award_type_codes: ASSISTANCE, program_numbers: [ "81.121" ] },
    "haleu_fuel_contracts" => { award_type_codes: CONTRACTS, keywords: [ "HALEU", "nuclear fuel" ] },
    "fusion" => { award_type_codes: ASSISTANCE, program_numbers: [ "81.049" ], keywords: [ "fusion" ] },
    # DOE's small-business (SBIR/STTR) grants (#125; SBIR.gov's API refuses
    # our bot): Office of Science grants to businesses from $100,000, the
    # size of a Phase I. USAspending doesn't mark a grant as SBIR, so only
    # those whose description is about nuclear energy work are kept
    # (NUCLEAR_ENERGY).
    "small_business" => { award_type_codes: ASSISTANCE, program_numbers: [ "81.049" ], min_amount: 100_000,
      keywords: [ "nuclear reactor", "advanced reactor", "nuclear fuel", "nuclear power", "spent fuel", "nuclear waste",
        "isotope production", "medical isotope", "HALEU", "TRISO", "molten salt reactor", "uranium enrichment" ] }
  }.freeze
  # The fusion search's keyword also finds awards that only mention fusion:
  # data fusion, plastics, and software, simulation or quantum computing run
  # on fusion data. Only awards for fusion energy work itself are kept: its
  # machines, magnets, lasers, plasma diagnostics and research.
  FUSION_ENERGY = /\b(?:fusion (?:energy|reactors?|magnets?|plasmas?|pilot plants?|program|facilit(?:y|ies))|inertial fusion|tokamaks?|stellarators?|burning plasma|for fusion\b)/i
  NUCLEAR_ENERGY = /\b(?:(?:nuclear|advanced|microreactors?|test) reactors?|microreactors?|nuclear (?:fuel|power|energy|plants?|waste)|spent (?:nuclear )?fuel|isotope production|medical isotopes?|HALEU|TRISO|molten salt (?:reactors?|fuel|coolant for (?:a |nuclear )?reactors?)|uranium enrichment)\b/i
  NOT_FUSION_ENERGY = /\b(?:data fusion|machine learning|data science|software|quantum|simulations?|meshing|computation)\b/i
  FIELDS = [ "Award ID", "Recipient Name", "Award Amount", "Start Date", "End Date", "Description", "generated_internal_id", "recipient_id" ].freeze
  # USAspending's recipient hash and level, e.g. "1f4e2b…-C".
  RECIPIENT_ID = /\A[0-9a-f-]+-[A-Z]\z/i
  # Legal suffixes a display name leaves out (DATA.md D1), and words kept as written.
  LEGAL_SUFFIX = /,?\s+(?:INC|INCORPORATED|LLC|L\.L\.C|CORP|CORPORATION|COMPANY|CO|LTD|LIMITED|LP|L\.P|LLP|PLLC|PBC)\.?\z/i
  ACRONYMS = %w[BWXT EPRI GE AMS PKMJ NOG USA US HALEU TRISO SMR 3M LLNL ORNL INL].freeze
  SMALL_WORDS = %w[of and the for in on at].freeze
  UNVERIFIED = { ai_recommendation: nil, ai_reason: nil, ai_confidence: nil, ai_model: nil, ai_checked_at: nil }.freeze
  # Line-of-business words a shared brand drops ("BWXT Nuclear" => "BWXT").
  GENERIC_WORDS = %w[nuclear energy power operations operating group services technologies technology holdings government].freeze
  COLUMNS = %w[award_id recipient_name amount_usd start_date end_date award_type assistance_listing search award_url
    generated_award_id recipient_id description].freeze

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(_run)
    # The repair runs before the refresh, so a name the refresh gives a pending record can't collide with one the repair sets.
    repaired = repair_approve_all
    reworded = { "repaired" => repaired, "reworded" => refresh_open_claims.size }.reject { |_, count| count.to_s == "0" }
    index = Source.find_or_create_by!(url: API_URL) do |source|
      source.source_kind = INDEX_SOURCE_KIND
      source.title = "USAspending.gov award search API"
    end
    stats = nil
    # At most once a day, recorded on the index source under its lock, as
    # Snapshot does for a page. The recipients and the fetch are written in
    # one savepoint (claim commits its lock even when the block raises): if
    # storing stops partway, nothing is kept and the day's fetch isn't
    # recorded, so a rerun fetches and stores them all.
    result = DataQuality::Snapshot.claim(index) do
      next :skipped_recent if index.fetched_at&.to_date == Date.current

      rows, failure = search_all
      Source.transaction(requires_new: true) do
        stats = { "awards" => rows.size }.merge(store_by_recipient(rows)) unless failure
        record(index, failure)
      end
    end
    return { "api" => result.to_s }.merge(reworded) unless result == :ok

    { "api" => "ok" }.merge(stats).merge(reworded)
  end

  # Claims still open from earlier crawls take this plug-in's current
  # wording and names (#302), as do the pending records the crawler made for
  # them (never one a person decided). A link whose wording changed after the
  # verifier disputed it goes back to verify, which this run's verify stage
  # then reads. A claim waiting on a person's same-company call keeps its
  # place. Once reworded, a claim reads the same again, so this changes
  # nothing on later runs. A pending company several claims share is named
  # after the words their names share ("BWXT" for "BWXT Nuclear Energy" and
  # "BWXT Nuclear Operations Group"), each spelling kept as an alias.
  # Returns what changed: [{ candidate:, changes:, reverify: }].
  def refresh_open_claims(by: "agent:#{source_kind}")
    directory = DataQuality::DirectoryClient.new
    open = Candidate.joins(:source).where(sources: { source_kind: }, status: %w[new matched needs_review]).includes(:source).order(:id).to_a
    fresh = open.to_h { |candidate| [ candidate.id, extract(candidate.source, nil).find { |item| item[:kind] == candidate.kind } ] }
    shared = open.select { |candidate| candidate.kind == "organization" && candidate.subject_id && fresh[candidate.id] }
      .group_by(&:subject_id).transform_values { |claims| shared_name(claims.map { |claim| fresh[claim.id][:payload]["name"] }) }
    open.filter_map do |loaded|
      item = fresh[loaded.id] or next

      Candidate.transaction do
        # Locked and read again: a claim a person decided meanwhile is left as decided.
        candidate = Candidate.lock.find_by(id: loaded.id)
        next unless candidate && %w[new matched needs_review].include?(candidate.status)

        payload = item[:payload]
        payload = payload.merge("name" => shared[candidate.subject_id]) if candidate.kind == "organization" && shared[candidate.subject_id]
        # The whole claim as extracted now, so its values stay consistent with each other.
        changes = payload.reject { |key, value| candidate.payload[key] == value }
        next if changes.empty?

        reverify = changes.key?("description") && candidate.status == "needs_review" && candidate.ai_recommendation.present?
        # Only a record this claim proposed: an existing company it was matched to keeps its name.
        record = directory.attached_record(candidate) if candidate.proposed_subject
        if record&.verification_status == "pending" && !record.verified_by.to_s.start_with?("human:")
          attributes = changes.slice(*(candidate.kind == "organization" ? %w[name aliases] : %w[description started_on])).symbolize_keys
          # Claims sharing it with no name in common: it keeps its own.
          attributes.delete(:name) if shared.key?(candidate.subject_id) && shared[candidate.subject_id].nil?
          if attributes.any?
            result = directory.write_pending(candidate.kind, attributes.merge(id: record.id), candidate:, crawl_run: nil, evidence: false)
            # Refused (its company was rejected meanwhile, or the new name is
            # another company's alias): left for a person, saying why, once;
            # the crawl goes on.
            if result.errors.any?
              why = "Not reworded: #{result.errors.to_sentence}. Same company?"
              candidate.update!(notes: [ candidate.notes, why ].compact_blank.join(" · ")) unless candidate.notes.to_s.include?(why)
              next
            end
          end
        end
        note = "Reworded for #302 by #{by}#{'; sent back to verify' if reverify}"
        # Back to verify: as matched when attached, else as new (matched needs a record).
        candidate.update!({ payload: candidate.payload.merge(changes), notes: [ candidate.notes, note ].compact_blank.join(" · ") }
          .merge(reverify ? { status: candidate.subject_id ? "matched" : "new" } : {})
          # A verdict on the old wording no longer holds: verify reads the claim again.
          .merge(reverify || %w[new matched].include?(candidate.status) ? UNVERIFIED : {}))
        { candidate:, changes:, reverify: }
      end
    end
  end

  # A company with any small-business grant (#125) waits for a person: the
  # search is new, a grant's description is all that says it's nuclear
  # work, and its grants join the same link's summary as the others.
  SMALL_BUSINESS_HOLD = "Has grants from the new small-business search: check they're nuclear energy work"

  def hold_for_review(candidate)
    searches = CSV.parse(candidate.source&.content_text.to_s, headers: true).filter_map { |row| row["search"] }
    SMALL_BUSINESS_HOLD if searches.include?("small_business")
  end

  # The facts every row's source states, which a single row doesn't repeat.
  def source_facts(source)
    return unless source.source_kind == source_kind

    "Each row is one award from the U.S. Department of Energy to the company named in it, from USAspending.gov's " \
      "award search: its award ID, amount in US dollars, start and end dates, and whether it's financial assistance " \
      "(a grant or cooperative agreement, with its Assistance Listing: 81.121 is Nuclear Energy research, development " \
      "and demonstration, 81.049 is the Office of Science) or a contract."
  end

  # The link's total, award count and first year come from every row, so the
  # verifier sees the recipient's whole table, header included, rather than
  # a passage around one award.
  # The count is stated, so the header line isn't taken for an award (#302).
  def verification_context(source, _quote)
    text = source.content_text.to_s
    rows = CSV.parse(text, headers: true).count { |row| row["recipient_name"].present? }
    "#{rows} #{rows == 1 ? 'award' : 'awards'}, one per row after the header line:\n#{text}"
  end

  def extract(source, _run)
    rows = CSV.parse(source.content_text.to_s, headers: true).select { |row| row["recipient_name"].present? }
    return [] if rows.empty?

    recipient = rows.first["recipient_name"]
    name = display_name(recipient)
    largest = rows.max_by { |row| row["amount_usd"].to_d }
    quote = largest.to_csv.chomp
    [
      { kind: "organization", payload: { "name" => name, "aliases" => ([ recipient ] if name != recipient) }.compact, quote: },
      { kind: "relationship", quote:, payload: {
        "from_organization" => { "name" => FUNDER }, "to_organization" => { "name" => recipient },
        "relationship_type" => "funds", "description" => summary(rows),
        "started_on" => rows.filter_map { |row| row["start_date"].presence }.min
      }.compact }
    ]
  end

  # A company's name as people read it, from the award's spelling (DATA.md
  # D1, #302): an all-capitals name in title case, its legal suffix dropped
  # ("BROOKHAVEN TECHNOLOGY GROUP INC" => "Brookhaven Technology Group"),
  # acronyms kept ("BWXT NUCLEAR ENERGY, INC." => "BWXT Nuclear Energy").
  # A name already in mixed case is the company's own and is kept.
  def display_name(spelling)
    spelling = spelling.to_s.squish
    return spelling unless spelling.match?(/[A-Z]/) && spelling == spelling.upcase

    name = spelling
    name = name.sub(LEGAL_SUFFIX, "") while name.match?(LEGAL_SUFFIX) && name.sub(LEGAL_SUFFIX, "").present?
    words = name.split(/(\s+|-|\/)/)
    words.each_with_index.map do |word, index|
      next word if word.match?(/\A(?:\s+|-|\/)\z/)
      next word if ACRONYMS.include?(word.delete(".,")) || (word.match?(/\A[A-Z&]{2,5}\z/) && !word.match?(/[AEIOU]/))
      next word.downcase if index.positive? && SMALL_WORDS.include?(word.downcase)

      word.capitalize
    end.join.delete_suffix(",").presence || spelling
  end

  private
    # The one-time repair of the 16 Oct approve-all (DataQuality::Repairs::
    # ApproveAll20261016), run here so it needs no shell. A value it doesn't
    # expect stops it, changing nothing, and is reported; the crawl goes on.
    def repair_approve_all
      DataQuality::Repairs::ApproveAll20261016.call.size
    rescue DataQuality::Repairs::ApproveAll20261016::Mismatch => error
      Rails.error.report(error, handled: true, context: { repair: "approve_all_2026_10_16" })
      "stopped: #{error.message.truncate(200)}"
    end

    # One name for claims that share a company: theirs when they agree, else
    # the words they all start with, without a trailing "and" or legal word;
    # nil when they share none (the record keeps its name).
    def shared_name(names)
      names = names.compact.uniq
      return names.first if names.size <= 1

      words = names.map(&:split)
      common = words.first.each_with_index.take_while { |word, index| words.all? { |other| other[index] == word } }.map(&:first)
      common.pop while common.any? && SMALL_WORDS.include?(common.last.downcase)
      # "BWXT Nuclear" is still BWXT: the brand, not the line of business.
      common.pop while common.size > 1 && GENERIC_WORDS.include?(common.last.downcase)
      common.join(" ").presence
    end

    # [rows, nil], or [nil, the Response that stopped it].
    def search_all
      rows = {}
      SEARCHES.each do |name, filters|
        more = true
        page = 0
        while more && page < MAX_PAGES
          page += 1
          response = @fetcher.post_json(API_URL, request_body(filters, page))
          return [ nil, response ] unless response.kind == :ok

          data = JSON.parse(response.body)
          data["results"].to_a.each do |award|
            next if name == "fusion" && !fusion_energy?(award["Description"])
            next if name == "small_business" && !award["Description"].to_s.match?(NUCLEAR_ENERGY)

            row = row_for(award, name)
            rows[row["generated_award_id"]] ||= row # an award two searches find is kept once
          end
          more = data.dig("page_metadata", "hasNext")
        end
        # More remain after the last page: a partial set would understate
        # totals, so nothing is stored and the snapshots stay as they are.
        return [ nil, failure("the #{name} search has more than #{MAX_PAGES * PAGE_SIZE} awards; raise MAX_PAGES") ] if more
      end
      [ rows.values, nil ]
    rescue JSON::ParserError => error
      [ nil, failure("USAspending answered with something that isn't JSON (#{error.message.truncate(80)})", status: 200) ]
    end

    def fusion_energy?(description)
      description.to_s.match?(FUSION_ENERGY) && !description.to_s.match?(NOT_FUSION_ENERGY)
    end

    def failure(reason, status: nil)
      DataQuality::Fetcher::Response.new(url: API_URL, kind: :error, status:, body: nil, etag: nil, last_modified: nil,
        reason:, block_reference: nil, content_type: nil, truncated: false)
    end

    def request_body(filters, page)
      contract = filters[:award_type_codes] == CONTRACTS
      {
        filters: filters.except(:min_amount).merge(
          agencies: [ { type: "awarding", tier: "toptier", name: "Department of Energy" } ],
          time_period: [ { start_date: YEARS.years.ago.to_date.iso8601, end_date: Date.current.iso8601 } ],
          award_amounts: [ { lower_bound: filters.fetch(:min_amount, MIN_AMOUNT) } ],
          recipient_type_names: [ "category_business" ]
        ),
        fields: contract ? FIELDS : FIELDS + [ "CFDA Number" ],
        page:, limit: PAGE_SIZE, sort: "Award Amount", order: "desc"
      }
    end

    def row_for(award, search)
      id = award["generated_internal_id"].to_s
      {
        "award_id" => award["Award ID"], "recipient_name" => award["Recipient Name"].to_s.strip,
        "amount_usd" => BigDecimal(award["Award Amount"].to_s).round(2).to_s("F"),
        "start_date" => award["Start Date"], "end_date" => award["End Date"],
        "award_type" => id.start_with?("CONT_") ? "contract" : "assistance", "assistance_listing" => award["CFDA Number"],
        "search" => search, "award_url" => "https://www.usaspending.gov/award/#{id}",
        "generated_award_id" => id, "recipient_id" => award["recipient_id"].to_s,
        "description" => award["Description"].to_s.squish.truncate(200)
      }
    end

    # The API's fetch recorded on the index source; :ok, or why not.
    def record(index, failure)
      attempt = { fetched_at: Time.current, http_status: failure ? failure.status : 200 } # nil: no answer (network, refused address)
      case failure&.kind
      when nil
        index.update!(attempt.merge(crawl_status: "ok", status_reason: nil, blocked_streak: 0))
        :ok
      when :blocked
        streak = index.blocked_streak + 1
        index.update!(attempt.merge(blocked_streak: streak, status_reason: failure.reason,
          crawl_status: streak >= DataQuality::Snapshot::BLOCKED_STREAK_LIMIT ? "needs_human" : "blocked"))
        :blocked
      when :disallowed
        index.update!(attempt.merge(crawl_status: "needs_human", status_reason: failure.reason))
        :disallowed
      else
        index.update!(attempt.merge(status_reason: failure.reason)) # temporary: try tomorrow
        :error
      end
    end

    # One source per recipient: its USAspending page, holding its awards' rows.
    # Rows are sorted, so the same awards give the same content (and hash).
    # An award without a usable recipient ID has no recipient page to cite,
    # so it's counted and left out rather than stopping the others.
    def store_by_recipient(rows)
      usable, unusable = rows.partition { |row| row["recipient_id"].match?(RECIPIENT_ID) }
      stats = { "recipients" => 0, "changed" => 0, "no_recipient_id" => unusable.size }
      usable.group_by { |row| row["recipient_id"] }.each do |recipient_id, awards|
        awards = awards.sort_by { |row| [ row["start_date"].to_s, row["award_id"].to_s ] }
        text = CSV.generate { |csv| csv << COLUMNS; awards.each { |row| csv << row.values_at(*COLUMNS) } }
        sha = Digest::SHA256.hexdigest(text)
        source = Source.find_or_create_by!(url: "https://www.usaspending.gov/recipient/#{recipient_id}/latest") do |new_source|
          new_source.source_kind = source_kind
          new_source.title = "USAspending.gov: Department of Energy awards to #{awards.first['recipient_name']}"
        end
        changed = source.content_sha256 != sha
        source.update!({ fetched_at: Time.current, crawl_status: "ok", status_reason: nil, http_status: 200 }
          .merge(changed ? { content_text: text, content_sha256: sha } : {}))
        stats["recipients"] += 1
        stats["changed"] += 1 if changed
      end
      stats
    end

    # "3 awards from the U.S. Department of Energy totaling $2.62 billion
    # (first in 2019, latest in 2026): DENE0009054, DENE0009040 and DENE0008928."
    # The years are when awards started, said so they can't be read as the
    # period the awards run (#302).
    def summary(rows)
      total = rows.sum { |row| row["amount_usd"].to_d }
      first, latest = rows.filter_map { |row| row["start_date"].to_s[0, 4].presence }.minmax
      years =
        if first.nil? then nil
        elsif rows.one? then " (#{first})"
        elsif first == latest then " (all in #{first})"
        else " (first in #{first}, latest in #{latest})"
        end
      ids = rows.sort_by { |row| -row["amount_usd"].to_d }.map { |row| row["award_id"] }
      listed = ids.size > 3 ? "#{ids.first(3).join(', ')} and #{ids.size - 3} more" : ids.to_sentence(last_word_connector: " and ")
      noun = rows.size == 1 ? "award" : "awards"
      "#{rows.size} #{noun} from the #{FUNDER} totaling #{dollars(total)}#{years}: #{listed}."
    end

    def dollars(amount)
      if amount >= 1_000_000_000 then "$#{(amount / 1_000_000_000).round(2).to_s('F')} billion"
      elsif amount >= 1_000_000 then "$#{(amount / 1_000_000).round(1).to_s('F')} million"
      else "$#{amount.round.to_i.to_fs(:delimited)}"
      end
    end
end
