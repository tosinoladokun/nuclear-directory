# The fixed rules a post must pass before it may go out (#769, PM 18 Nov, from the Founder's rule set): code, never a
# model's opinion. Each returns problems; any one stops the post (fail closed).
module SocialAgent::Rules
  # Primary sources only: government, regulators, labs and the company's own site (Founder 3.2).
  PRIMARY_HOSTS = /(\A|\.)(gov|mil)\z|\A(www\.)?(federalregister\.gov|iaea\.org|world-nuclear\.org)\z/
  # A status word in the post must be the source's own (Founder 3.5): received isn't approved, a framework isn't signed.
  STATUS_WORDS = %w[received accepted approved approval signed signs executed announced awarded award issued granted licensed
    completed operating operational contract binding definitive].freeze
  # DQ's deal and plant distinctions (DATA.md: a framework isn't a contract, a loan is a loan, a permit received isn't
  # issued): a term in the post needs the same stem in the source. Term found in the post => stem looked for in the source.
  STATUS_TERMS = {
    /\bagreements?\b/i => /agree/i, /\bdeals?\b/i => /\bdeal/i, /\bpartner(ship)?s?\b/i => /partner/i, /\bframeworks?\b/i => /framework/i,
    /\b(memorandum|MOU)\b/i => /memorandum|\bmou\b/i, /\b(letter of intent|LOI)\b/i => /letter of intent|\bloi\b/i,
    /\boptions?\b/i => /\boption/i, /\bpre-?orders?\b/i => /pre-?order/i, /\bloans?\b/i => /\bloan/i,
    /\bfund(ed|ing|s)?\b/i => /\bfund/i, /\binvest(ed|ment|ments|s)?\b/i => /invest/i, /\bacqui(red|res|sition)\b/i => /acqui/i,
    /\bmerg(er|ed|es)\b/i => /merg/i, /\brestart(ed|s)?\b/i => /restart/i, /\bconstruct(ion|ed|ing)?\b/i => /construct/i,
    /\bpermits?\b/i => /permit/i, /\bproduc(e|es|ed|ing|tion)\b/i => /produc/i, /\bonline\b/i => /online/i,
    /\bconnected\b/i => /connect/i, /\bgrid\b/i => /\bgrid/i, /\bcapacity\b/i => /capacity/i, /\b(MW|MWe|MWt|GW)\b/ => /\b(MW|MWe|MWt|GW)\b/,
    /\bshut( ?down)?\b/i => /shut/i, /\bdecommission(ed|ing)?\b/i => /decommission/i
  }.freeze
  SUPERLATIVES = /\b(largest|biggest|first|only|smallest|fastest|most|record|unprecedented|leading|best|world's)\b/i
  SENSITIVE = /\b(incidents?|accidents?|injur\w*|casualt\w*|deaths?|died|killed|fatal\w*|leak\w*|contaminat\w*|evacuat\w*|security|
    terror\w*|attack\w*|sabotage|theft|stolen|weapon\w*|warheads?|pit\s+production|export\s+controls?|lawsuits?|litigation|indict\w*)\b/ix
  # On the fetched page (menus included), a narrower list: a regulator's page always has "Security" in its menu.
  LEDE = 800
  PAGE_SENSITIVE = /\b(incidents?|accidents?|casualt\w*|killed|fatal\w*|contaminat\w*|evacuat\w*|sabotage|theft|stolen|weapons?)\b/i
  MONTHS = Date::MONTHNAMES.compact.freeze
  STATES = %w[Alabama Alaska Arizona Arkansas California Colorado Connecticut Delaware Florida Georgia Hawaii Idaho Illinois
    Indiana Iowa Kansas Kentucky Louisiana Maine Maryland Massachusetts Michigan Minnesota Mississippi Missouri Montana Nebraska
    Nevada Hampshire Jersey Mexico York Carolina Dakota Ohio Oklahoma Oregon Pennsylvania Rhode Island Tennessee Texas Utah
    Vermont Virginia Washington Wisconsin Wyoming New North South West].freeze
  # A place, not a person (shadow day 20 Nov: "Southeast Asia" was taken for one): only region and compass words
  # ("Southeast Asia", "Middle East"), or region words before one country ("South Korea", "South Africa"). A country
  # alone never clears a run, so "Chad Jordan" is still a name.
  REGIONS = %w[Asia Europe Africa America Americas Pacific Atlantic Arctic Antarctica Middle East Southeast Northeast
    Southwest Northwest Central Eastern Western Northern Southern North South West Gulf Caribbean Latin Baltic Nordic
    Scandinavia Oceania].to_set.freeze
  # Whole country names, parentheses dropped ("Korea (South)" is "Korea"): never a first word of a longer name
  # (Copilot: "Cook" from "Cook Islands" would clear "Asia Cook").
  COUNTRIES = (TZInfo::Country.all.map { |country| country.name.sub(/\s*\(.*\)\z/, "").sub(/,.*\z/, "") } +
    [ "United States", "United Kingdom", "Czech Republic", "United Arab Emirates", "Saudi Arabia", "New Zealand" ]).to_set.freeze

  def self.place?(words)
    return true if words.all? { |word| REGIONS.include?(word) }

    rest = words.drop_while { |word| REGIONS.include?(word) }
    rest.any? && COUNTRIES.include?(rest.join(" "))
  end
  # A word that makes a capitalised run an organisation, place or thing rather than a person.
  ARTICLES = %w[The A An This That These Those].freeze
  NOT_PERSON = %w[Pte Ltd Limited GmbH AG PLC SA Inc Corp Infrastructure Challenge Summit Prize Award Conference Forum Initiative
    Mission Facility Environmental Statement Department Energy Commission Agency Laboratory Lab National Nuclear Regulatory Office Administration
    Authority University Institute Corporation Company Inc LLC Power Station Plant Unit Units Reactor Project Program Federal Register
    Fund Bank Group Energy Fuel Fuels Technologies Systems Services Holdings Partners Capital Industries Electric Utility Council
    Board Court Congress Senate House Army Navy Air Force Generating Clean Center Centre Site County City River Lake Valley].freeze
  SIMILAR = 0.85
  SIMILAR_DAYS = 60

  module_function

  def problems(text, item, platform:, fetcher: DataQuality::Fetcher.new)
    found = []
    found << "its source isn't a primary one (#{host(item.source_url).presence || 'none'})" unless primary?(item)
    found.concat(status_words(text, item))
    found.concat(people(text, item))
    found.concat(dates(text, item))
    found.concat(qualifiers(text, item))
    found << "it says the same thing twice" if repeats?(text)
    found << "it says the publisher \"said\" it \"announced\": say what it did, with the source's own verb" if text.match?(/\bsaid\b[^.]{0,80}\bannounced\b/i)
    unsupported_superlatives(text, item).each { |word| found << "it says #{word.inspect}, which its source doesn't" }
    found << "it touches a sensitive topic (#{$1.downcase})" if "#{text}\n#{item.own_text}" =~ SENSITIVE
    found << "it's too like a post from the last #{SIMILAR_DAYS} days" if similar?(text, platform)
    found.concat(source_problems(item.source_url, fetcher, item:, text:)) if found.empty?
    found
  end

  # A date in a news post must be its item's own date (PM, 20 Nov: the page's published date); in any other post it must
  # be written in the source. "19 November", "November 19" and "19 November 2026" all count.
  MONTH = Date::MONTHNAMES.compact.join("|")
  # "19 November", "November 19", each with an optional year (Copilot: the year must match too).
  DATE = /\b(?:(\d{1,2})\s+(#{MONTH})|(#{MONTH})\s+(\d{1,2}))(?:,?\s+(\d{4}))?\b/
  def dates(text, item)
    own = Date.parse(item.facts["date"].to_s) rescue nil
    source = [ item.source_quote, item.page_text ].compact.join("\n")
    text.scan(DATE).filter_map do |day_first, month_a, month_b, day_last, year|
      day, month = (day_first || day_last).to_i, Date::MONTHNAMES.index(month_a || month_b)
      name = Date::MONTHNAMES[month]
      year_part = year ? ",?\\s+#{year}" : ""
      # The item's own date (and year), or a date its source states the same way (a deadline, a closing date).
      stated = source.match?(/\b(?:#{day}\s+#{name}#{year_part}|#{name}\s+#{day}#{year_part})\b/i)
      own_date = item.kind == "news" && own && own.day == day && own.month == month && (year.nil? || year.to_i == own.year)
      next if stated || own_date

      item.kind == "news" && own ? "the date #{day} #{Date::MONTHNAMES[month]} isn't the item's own (#{item.facts['date']}) or in the source" : "the date #{day} #{Date::MONTHNAMES[month]} isn't in the source"
    end
  end

  # A page's main text: its article or main element, without scripts, menus, headers and footers.
  def article_text(body)
    doc = Nokogiri::HTML(body.to_s)
    doc.css("script, style, nav, header, footer, noscript, aside").remove
    (doc.at_css("article, main") || doc.at_css("body") || doc).text.squish
  end

  # The page states the date, in its text or its datePublished/published_time: "November 19, 2026", "19 November 2026",
  # "Nov 19, 2026", "2026-11-19" or "11/19/2026".
  def page_dated?(body, date_text)
    date = Date.parse(date_text.to_s) rescue (return true) # no date to check
    text = ActionController::Base.helpers.strip_tags(body).squish
    meta = body.scan(/(?:datePublished|published_time|article:published|pubdate)[^0-9]{0,40}(\d{4}-\d{2}-\d{2})/i).flatten
    forms = [ date.strftime("%B %-d, %Y"), date.strftime("%-d %B %Y"), date.strftime("%b %-d, %Y"), date.strftime("%b. %-d, %Y"),
      date.iso8601, date.strftime("%m/%d/%Y"), date.strftime("%-m/%-d/%Y") ]
    # Whole forms only: "19 November 2026" isn't "9 November 2026" (Copilot).
    meta.include?(date.iso8601) || forms.any? { |form| text.match?(/(?<![\d\/])#{Regexp.escape(form)}(?![\d\/])/) }
  end

  # What the source doesn't say isn't said (GTM, 20 Nov: "provides no further details" was false), and a qualifier the
  # source puts on the deal stays on it (an MOU, a non-binding framework, a letter of intent).
  ABSENCE = Regexp.union([ "no further details", "no other details", "did not disclose", "didn't disclose", "did not say", "didn't say",
    "not disclosed", "undisclosed", "gave no details", "nothing else", "no details were given", "no details were provided" ]
    .map { |phrase| /\b#{Regexp.escape(phrase)}\b/i })
  QUALIFIERS = { /memorandum of understanding|\bMOU\b/i => "MOU", /non-binding/i => "non-binding", /letter of intent|\bLOI\b/i => "letter of intent",
                 /framework agreement/i => "framework agreement", /\bproposed\b/i => "proposed", /\bplanned\b/i => "planned" }.freeze
  # A deal word in the post must be the source's own word (DQ: "a collaboration" for a signed MOU).
  DEAL_WORDS = { "an MOU" => /\bMOUs?\b|memorand(?:um|a) of understanding/i, "a framework" => /\bframeworks?\b/i,
    "an agreement" => /\bagreements?\b/i, "a partnership" => /\bpartnerships?\b/i, "a collaboration" => /\bcollaborations?\b/i,
    "a contract" => /\bcontracts?\b/i, "a deal" => /\bdeals?\b/i, "an alliance" => /\balliances?\b/i, "a venture" => /\bventures?\b/i }.freeze
  def qualifiers(text, item)
    found = []
    # Each absence phrase on its own: the source saying "not disclosed" doesn't allow "no further details" (Copilot).
    text.scan(ABSENCE).map { |match| Array(match).first || match }.uniq.each do |phrase|
      found << "it says #{phrase.downcase.inspect}, which its source doesn't" unless item.source_text.match?(/\b#{Regexp.escape(phrase)}\b/i)
    end
    DEAL_WORDS.each do |name, pattern|
      found << "it calls it #{name}, which its source doesn't" if text.match?(pattern) && !item.source_text.match?(pattern)
    end
    QUALIFIERS.each do |pattern, name|
      # "Proposed" and "planned" count only in the item's own words: a page's other stories have their own plans.
      said = %w[proposed planned].include?(name) ? item.own_text : item.source_text
      found << "it leaves out the source's qualifier (#{name})" if said.match?(pattern) && !text.match?(pattern)
    end
    found
  end

  # Two sentences sharing most of the shorter one's words say the same thing (GTM: a second paragraph restating the first).
  REPEAT = 0.6
  STOP = %w[the a an and or of to in on for with by at as is are was were its it that this from be will has have said].to_set.freeze
  def repeats?(text)
    sentences = text.split(/(?<=[.!?])\s+/).map { |sentence| sentence.downcase.scan(/[a-z0-9]+/).to_set - STOP }.select { |words| words.size >= 4 }
    numbers = ->(words) { words.select { |word| word.match?(/\A\d/) }.to_set }
    # Different quantities are different facts ("50 MW of electricity", "100 MW of heat"; Copilot): not a repeat.
    sentences.combination(2).any? do |a, b|
      quantities = [ numbers.(a), numbers.(b) ]
      next false if quantities.all?(&:any?) && quantities.uniq.size > 1

      (a & b).size.to_f / [ a.size, b.size ].min >= REPEAT
    end
  end

  def host(url) = (URI.parse(url.to_s).host.to_s.downcase rescue "")

  # A government or regulator page, or the company's own site.
  def primary?(item)
    host = host(item.source_url).delete_prefix("www.")
    return false if host.blank?
    return true if host.match?(PRIMARY_HOSTS)

    own_site = Organization.where(id: item.organization_ids).pluck(:domain, :website).flatten.compact.any? do |site|
      own = (site.include?("/") ? host(site) : site).delete_prefix("www.")
      own.present? && (host == own || host.end_with?(".#{own}"))
    end
    return false if host.match?(OUTLETS)

    own_site || publishers_site?(host, item.facts["publisher"]) || known_domain?(host, item)
  end

  # News outlets and wires are never primary, whatever their name (DQ: a wire copy isn't the issuer's own site).
  OUTLETS = /(\A|\.)(prnewswire|businesswire|globenewswire|einpresswire|accesswire|newswire|newsfilecorp|prweb|reuters|apnews|bloomberg|
    world-nuclear-news|neimagazine|ans|utilitydive|powermag|eenews|energy-reporters|nucnet|power-eng|powerengineeringint|
    nuclearnewswire|ft|wsj|nytimes|washingtonpost|cnbc|forbes|yahoo|marketwatch|seekingalpha)\.(com|org|net|co\.uk)\z/x

  # The site is a company's known domain or website in the directory (pending too: a company not yet listed, PM 20 Nov),
  # and that company is the item's publisher or one it names.
  def known_domain?(host, item)
    names = [ item.facts["publisher"], *item.facts["companies"].to_s.split(", ") ].compact_blank.map { |name| name.squish.downcase }
    return false if names.empty?

    Organization.where(verification_status: %w[verified pending]).where("lower(name) IN (?)", names).pluck(:domain, :website).flatten.compact.any? do |site|
      own = (site.include?("/") ? host(site) : site).downcase.delete_prefix("www.")
      own.present? && (host == own || host.end_with?(".#{own}"))
    end
  end

  # A news item's publisher on its own site, by name (DQ, shadow day 20 Nov: Deep Isolation's release on
  # deepisolation.com, while the company isn't listed yet): the site's name is the publisher's, legal ending aside.
  LEGAL_ENDINGS = /(inc|incorporated|corp|corporation|co|company|llc|ltd|plc|lp|group|holdings)\z/
  def publishers_site?(host, publisher)
    name = publisher.to_s.downcase.gsub(/[^a-z0-9]/, "")
    label = host.split(".")[-2].to_s.delete("-")
    return false if name.length < 4 || label.length < 4

    [ name, name.sub(LEGAL_ENDINGS, "") ].include?(label)
  end

  def status_words(text, item)
    source = item.source_text.downcase
    words = STATUS_WORDS.filter_map do |word|
      next unless text.match?(/\b#{word}\b/i)

      stem = word.sub(/(ed|s|al|ion)\z/, "")
      "it says #{word.inspect}, which its source doesn't" unless source.match?(/\b#{Regexp.escape(stem)}/)
    end
    terms = STATUS_TERMS.filter_map do |term, stem|
      said = text[term] or next
      "it says #{said.downcase.inspect}, which its source doesn't" unless item.source_text.match?(stem)
    end
    (words + terms).uniq
  end

  # Two or more capitalised words in a row are a name: allowed only for a company, plant or place the directory knows,
  # the facts' own companies and publisher, a month or a state; anything else may be a person (Founder 3.7).
  def people(text, item)
    known = [ item.facts["companies"], item.facts["name"], item.facts["publisher"] ].compact.join(" ").downcase
    text.scan(/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b/).uniq.filter_map do |found|
      # An article isn't a name, nor evidence of an organisation (Copilot: "The Jane Doe statement").
      words = found.split.drop_while { |word| ARTICLES.include?(word) }
      next if words.size < 2

      phrase = words.join(" ")
      next if words.all? { |word| MONTHS.include?(word) || STATES.include?(word) } || place?(words)
      next if words.any? { |word| NOT_PERSON.include?(word) }
      next if known.include?(phrase.downcase) || directory_name?(phrase)

      "it may name a person (#{phrase})"
    end
  end

  def directory_name?(phrase)
    # The whole name or another name, never a part of one: "Jane Doe" inside "Jane Doe Engineering" is still a person (DQ).
    name = phrase.downcase
    Organization.where("lower(name) = ?", name).exists? || Facility.where("lower(name) = ?", name).exists? ||
      OrganizationAlias.where("lower(alias) = ?", name).exists? || FacilityAlias.where("lower(alias) = ?", name).exists?
  end

  # Every superlative in the post, each needing the same word in its source (Copilot).
  def unsupported_superlatives(text, item)
    text.scan(SUPERLATIVES).flatten.map(&:downcase).uniq.reject { |word| item.source_text.match?(/\b#{Regexp.escape(word)}\b/i) }
  end

  def similar?(text, platform)
    mine = tokens(text)
    SocialPost.used.where(platform:, created_at: SIMILAR_DAYS.days.ago..).where.not(text: nil).pluck(:text).any? do |other|
      theirs = tokens(other)
      (mine & theirs).size.to_f / [ (mine | theirs).size, 1 ].max >= SIMILAR
    end
  end

  def tokens(text) = text.downcase.scan(/[[:alnum:]]+/).uniq

  # The source must answer 200 now (Founder 3.1: fetched within the last day); a block is a block, never retried.
  # Its page is checked for sensitive topics too, beyond the saved quote (Copilot).
  def source_problems(url, fetcher, item: nil, text: nil)
    response = fetcher.get(url.to_s)
    return [ "its source didn't answer (#{response.status || response.reason})" ] unless response.kind == :ok && response.status == 200

    # The article's subject, not a word in passing (rehearsal: "beyond any credible accident scenario" in a permit story,
    # "safety incident rates improved"): in its opening, or three times or more.
    article = article_text(response.body.to_s)
    hits = article.scan(PAGE_SENSITIVE).flatten
    topic = article.first(LEDE)[PAGE_SENSITIVE] || (hits.first if hits.size >= 3)
    return [ "its source page touches a sensitive topic (#{topic.downcase})" ] if topic
    # A news post's date must be the page's own (DQ, 20 Nov: NASA's pulsar item showed a date the page didn't).
    return [ "its date (#{item.facts['date']}) isn't on the source page" ] if item&.kind == "news" && !page_dated?(response.body.to_s, item.facts["date"])
    # The page's own words too: an MOU the title doesn't mention is still an MOU (rehearsal, 20 Nov).
    return [] unless item && text

    page = item.with(source_quote: [ item.source_quote, ActionController::Base.helpers.strip_tags(response.body.to_s).squish.first(20_000) ].join("\n"))
    qualifiers(text, page).reject { |problem| problem.start_with?("it calls it", "it says") }
  rescue StandardError => error
    [ "its source didn't answer (#{error.class})" ]
  end

  # US federal holidays (5 U.S.C. 6103), with Saturday ones observed Friday and Sunday ones Monday.
  def holiday?(date)
    year = date.year
    nth = ->(month, weekday, n) { first = Date.new(year, month, 1); first + ((weekday - first.wday) % 7) + (7 * (n - 1)) }
    last_monday = ->(month) { last = Date.new(year, month, -1); last - ((last.wday - 1) % 7) }
    fixed = [ [ 1, 1 ], [ 6, 19 ], [ 7, 4 ], [ 11, 11 ], [ 12, 25 ] ].map { |month, day| Date.new(year, month, day) }
    fixed += [ Date.new(year + 1, 1, 1) ] # observed on 31 December when New Year's Day is a Saturday
    observed = fixed.map { |day| day.saturday? ? day - 1 : (day.sunday? ? day + 1 : day) }
    floating = [ nth.(1, 1, 3), nth.(2, 1, 3), last_monday.(5), nth.(9, 1, 1), nth.(10, 1, 2), nth.(11, 4, 4) ]
    (observed + floating).include?(date)
  end
end
