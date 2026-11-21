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
    Mission Facility Operations Asset Management Investment Investments Ventures Environmental Statement Department Energy Commission Agency Laboratory Lab National Nuclear Regulatory Office Administration
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
    found.concat(tags(text, item))
    found.concat(headquarters(text, item))
    found.concat(dates(text, item))
    found.concat(qualifiers(text, item))
    found.concat(speaker_problems(text, item))
    found.concat(act_problems(text, item))
    found.concat(tense_problems(text))
    found.concat(unattributed_superlatives(text))
    found << "it says the same thing twice" if repeats?(text)
    found << "it says the publisher \"said\" it \"announced\": say what it did, with the source's own verb" if text.match?(/\bsaid\b[^.]{0,80}\bannounced\b/i)
    unsupported_superlatives(text, item).each { |word| found << "it says #{word.inspect}, which its source doesn't" }
    found << "it touches a sensitive topic (#{$1.downcase})" if "#{text}\n#{item.own_text}" =~ SENSITIVE
    found << "it's too like a post from the last #{SIMILAR_DAYS} days" if similar?(text, platform)
    found.concat(source_problems(item.source_url, fetcher, item:, text:)) if found.empty?
    # Last, so the source's own problems (it didn't answer, a sensitive page) are what a post that has them is told.
    found << "it doesn't say where the item comes from in words (\"the company said\", \"DOE said\", \"in a Federal Register notice\")" if found.empty? && !attributed?(text)
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
  # Several <article>s (a list of stories) or a thin one (a headline, the body in a div beside it) read as the longest of them;
  # under MIN_ARTICLE characters the whole body is the article (GTM, round 17: BWXT's quote was its headline plus an unrelated
  # story's).
  MIN_ARTICLE = 600
  def article_text(body)
    doc = Nokogiri::HTML(body.to_s)
    doc.css("script, style, nav, header, footer, noscript, aside").remove
    texts = doc.css("article, main").map { |node| node.text.squish }
    best = texts.max_by(&:length).to_s
    return best if best.length >= MIN_ARTICLE

    [ best, (doc.at_css("body") || doc).text.squish ].max_by(&:length)
  end

  # A PDF's bytes aren't a page (GTM, round 17: a Leapfrog quote was raw PDF bytes): the agent has no PDF reader, so a source that
  # is one isn't used.
  def pdf?(response) = response.content_type.to_s.include?("pdf") || response.body.to_s.byteslice(0, 5) == "%PDF-"

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
    "not disclosed", "undisclosed", "gave no details", "nothing else", "no details were given", "no details were provided",
    "gave no figure", "gave a figure", "did not give", "didn't give", "declined to", "has not said", "hasn't said", "has not disclosed" ]
    .map { |phrase| /\b#{Regexp.escape(phrase)}\b/i } + [ /\bneither\b[^.]{0,40}\bgave\b/i ])
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

  # The source named in words (Tosin, 20 Nov: the post's link is our page; the source is only said): a verb of saying or a
  # document word. The writer is told to; this is the check.
  ATTRIBUTION = /\b(said|says|announced|announces|reported|reports|stated|states|confirmed|according\s+to|per\s+(?:its|the|our|(?-i:[A-Z])\w*)|told|issued|released|published|filed|
    (?:in|from|through)\s+(?:a|an|its|the)\s+[\w\s.'-]{0,40}?(?:notice|filing|release|statement|report|order|letter|permit|announcement|page|post|article))\b/ix
  def attributed?(text) = text.match?(ATTRIBUTION)

  # A government document is its agency's, not the company's (GTM, round 17: an NRC letter assigning a project number was
  # "Leapfrog said"). On a government page, a company named in the facts doesn't "say" or "announce" it.
  SPEECH = /\b(said|says|announced|announces|stated|states|reported|reports|confirmed|filed|told|unveiled|revealed)\b/i
  def speaker_problems(text, item)
    return [] unless host(item.source_url).delete_prefix("www.").match?(PRIMARY_HOSTS)

    names = item.facts["companies"].to_s.split(", ").compact_blank + item.organization_ids.then { |ids| Organization.where(id: ids).pluck(:name) }
    # The agency itself speaking is fine: NASA on nasa.gov, DOE on energy.gov (the publisher, or a name in the host).
    own = [ item.facts["publisher"].to_s.downcase, host(item.source_url) ]
    names.uniq.reject { |name| own.first == name.downcase || own.last.delete("-").include?(name.downcase.delete(" ")) }.filter_map do |name|
      next unless text.match?(/#{Regexp.escape(name)}\s+(?:\w+\s+){0,2}#{SPEECH}/i)

      "it says #{name} #{text[/#{Regexp.escape(name)}\s+(?:\w+\s+){0,2}(#{SPEECH.source})/i, 1].to_s.downcase}, but its source is a government document: say who issued it (\"the NRC said\", \"in an NRC letter\")"
    end
  end

  # A regulator's act is the source's own word (DQ, round 17: a permit "authorized" where DOE says "approved"): each of these in the
  # post must be in the source, as the verb of that act.
  ACTS = %w[authorize authorized approve approved licensed permitted certified cleared].freeze
  def act_problems(text, item)
    source = item.source_text.downcase
    text.downcase.scan(/\b(?:#{ACTS.join('|')})\b/).uniq.reject { |word| source.match?(/\b#{word.sub(/(?:ed|d)\z/, '')}\w*/) }.map do |word|
      "it says \"#{word}\", which isn't the source's word for the act (use the source's own verb)"
    end
  end

  # A dated event is told in the past tense (GTM, round 17: "said on 27 October ... signs" was blocked).
  PRESENT_NEWS = /\b(signs|announces|launches|awards|receives|closes|issues|unveils|completes|secures|establishes)\b/i
  def tense_problems(text)
    return [] unless text.match?(DATE) && (verb = text[PRESENT_NEWS, 1])

    [ "it dates the event but writes \"#{verb.downcase}\" in the present tense: use the past (signed, announced)" ]
  end

  # A superlative the source claims is attributed to it, not stated as fact (DQ, round 17: "DOE calls it the first ...").
  CLAIM_CUE = /\b(calls?|called|describes?|described|says?|said|claims?|claimed|according to|billed|labels?|labelled|touts?)\b/i
  def unattributed_superlatives(text)
    text.split(/(?<=[.!?])\s+/).filter_map do |sentence|
      # "the first phase", "the first two units" put things in order: they aren't a claim to be first.
      word = sentence.gsub(/\bfirst\s+(?:phase|stage|unit|units|quarter|half|year|round|two|three|four|five|six|seven|eight|nine|ten|\d+\w*)\b/i, "")[SUPERLATIVES, 1]
      next unless word
      next if sentence.match?(CLAIM_CUE)

      "it states \"#{word.downcase}\" as fact: attribute the claim to its source (\"DOE calls it the first ...\")"
    end.uniq
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

  # Where a spotlight puts the company is the directory's headquarters, nothing else on the page (Founder/DQ, Helion: "Redmond" was the
  # 2014 award's project location, the headquarters is Everett).
  PLACED = /\b(?:based|headquartered|headquarters(?:\s+(?:is|are))?)\s+in\s+([A-Z][\p{L}.'-]*(?:\s+[A-Z][\p{L}.'-]*)*)/
  def headquarters(text, item)
    return [] unless item.kind == "spotlight"

    hq = item.facts["headquarters"].to_s
    text.scan(PLACED).flatten.filter_map do |place|
      next if hq.downcase.include?(place.downcase)

      hq.present? ? "it puts the company in #{place}, but its headquarters in the directory is #{hq}" : "it says where the company is (#{place}), but the directory has no headquarters for it"
    end
  end

  # An @ account in a post is only the company's own verified X handle (GTM's list, #883): never another account, never on LinkedIn.
  def tags(text, item)
    allowed = item.facts["x_handle"].to_s.downcase
    text.scan(/@\w+/).uniq.filter_map { |tag| "it tags #{tag}, which isn't this company's verified handle" unless tag.downcase == allowed }
  end

  # Two or more capitalised words in a row are a name: allowed only for a company, plant or place the directory knows,
  # the facts' own companies and publisher, a month or a state; anything else may be a person (Founder 3.7).
  def people(text, item)
    known = [ item.facts["companies"], item.facts["name"], item.facts["publisher"] ].compact.join(" ").downcase
    text.scan(/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b/).uniq.filter_map do |found|
      # An article isn't a name, nor evidence of an organisation (Copilot: "The Jane Doe statement").
      words = found.split.drop_while { |word| ARTICLES.include?(word) || (word == "Meet" && item.kind == "spotlight") }
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
    return [ "its source is a PDF, which the agent can't read yet: no grounding for a post" ] if pdf?(response)

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
