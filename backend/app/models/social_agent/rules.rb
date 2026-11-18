# The fixed rules a post must pass before it may go out (#769, PM 18 Nov, from the Founder's rule set): code, never a
# model's opinion. Each returns problems; any one stops the post (fail closed).
module SocialAgent::Rules
  # Primary sources only: government, regulators, labs and the company's own site (Founder 3.2).
  PRIMARY_HOSTS = /(\A|\.)(gov|mil)\z|\A(www\.)?(federalregister\.gov|iaea\.org|world-nuclear\.org)\z/
  # A status word in the post must be the source's own (Founder 3.5): received isn't approved, a framework isn't signed.
  STATUS_WORDS = %w[received accepted approved approval signed signs executed announced awarded award issued granted licensed
    completed operating operational contract binding definitive].freeze
  SUPERLATIVES = /\b(largest|biggest|first|only|smallest|fastest|most|record|unprecedented|leading|best|world's)\b/i
  SENSITIVE = /\b(incident|accident|injur\w*|casualt\w*|death|died|killed|fatal\w*|leak\w*|contaminat\w*|evacuat\w*|security|
    terror\w*|attack\w*|sabotage|theft|stolen|weapon\w*|export control\w*|lawsuit|litigation|indict\w*)\b/ix
  MONTHS = Date::MONTHNAMES.compact.freeze
  STATES = %w[Alabama Alaska Arizona Arkansas California Colorado Connecticut Delaware Florida Georgia Hawaii Idaho Illinois
    Indiana Iowa Kansas Kentucky Louisiana Maine Maryland Massachusetts Michigan Minnesota Mississippi Missouri Montana Nebraska
    Nevada Hampshire Jersey Mexico York Carolina Dakota Ohio Oklahoma Oregon Pennsylvania Rhode Island Tennessee Texas Utah
    Vermont Virginia Washington Wisconsin Wyoming New North South West].freeze
  # A word that makes a capitalised run an organisation, place or thing rather than a person.
  NOT_PERSON = %w[The A An Department Energy Commission Agency Laboratory Lab National Nuclear Regulatory Office Administration
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
    found << "it says #{text[SUPERLATIVES].downcase.inspect}, which its source doesn't" if superlative?(text, item)
    found << "it touches a sensitive topic (#{(text + item.source_text)[SENSITIVE].downcase})" if (text + "\n" + item.source_text).match?(SENSITIVE)
    found << "it's too like a post from the last #{SIMILAR_DAYS} days" if similar?(text, platform)
    found << source_unreachable(item.source_url, fetcher) if found.empty?
    found.compact
  end

  def host(url) = (URI.parse(url.to_s).host.to_s.downcase rescue "")

  # A government or regulator page, or the company's own site.
  def primary?(item)
    host = host(item.source_url).delete_prefix("www.")
    return false if host.blank?
    return true if host.match?(PRIMARY_HOSTS)

    Organization.where(id: item.organization_ids).pluck(:domain, :website).flatten.compact.any? do |site|
      own = (site.include?("/") ? host(site) : site).delete_prefix("www.")
      own.present? && (host == own || host.end_with?(".#{own}"))
    end
  end

  def status_words(text, item)
    source = item.source_text.downcase
    STATUS_WORDS.filter_map do |word|
      next unless text.match?(/\b#{word}\b/i)

      stem = word.sub(/(ed|s|al|ion)\z/, "")
      "it says #{word.inspect}, which its source doesn't" unless source.match?(/\b#{Regexp.escape(stem)}/)
    end
  end

  # Two or more capitalised words in a row are a name: allowed only for a company, plant or place the directory knows,
  # the facts' own companies and publisher, a month or a state; anything else may be a person (Founder 3.7).
  def people(text, item)
    known = [ item.facts["companies"], item.facts["name"], item.facts["publisher"] ].compact.join(" ").downcase
    text.scan(/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b/).uniq.filter_map do |phrase|
      words = phrase.split
      next if words.all? { |word| MONTHS.include?(word) || STATES.include?(word) }
      next if words.any? { |word| NOT_PERSON.include?(word) }
      next if known.include?(phrase.downcase) || directory_name?(phrase)

      "it may name a person (#{phrase})"
    end
  end

  def directory_name?(phrase)
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(phrase.downcase)}%"
    Organization.where("lower(name) LIKE ?", pattern).exists? || Facility.where("lower(name) LIKE ?", pattern).exists? ||
      OrganizationAlias.where("lower(alias) LIKE ?", pattern).exists?
  end

  def superlative?(text, item)
    word = text[SUPERLATIVES] or return false
    !item.source_text.match?(/\b#{Regexp.escape(word)}\b/i)
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
  def source_unreachable(url, fetcher)
    response = fetcher.get(url.to_s)
    "its source didn't answer (#{response.status || response.reason})" unless response.kind == :ok && response.status == 200
  rescue StandardError => error
    "its source didn't answer (#{error.class})"
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
