# The automated fact check (#769), in code: a draft may use only what its source and facts say. Every number in
# it must appear in them, as must every name (each capitalised word); no link of its own, no hashtag or
# emoji, and it fits the platform. Returns the problems, empty when it passes.
module SocialAgent::Check
  X_LIMIT = 280
  # X counts any link as 23 characters.
  X_LINK = 23
  LINKEDIN_LIMIT = 1_300
  ALWAYS_ALLOWED = [ "Nuclear Directory", "Nuclear", "Directory", "US", "U.S." ].freeze

  module_function

  def problems(text, item, platform:)
    source = normalize(item.source_text)
    stated = numbers(item.source_text)
    found = []
    return [ "it's empty or a placeholder" ] if text.to_s.strip.length < 20 || text.match?(/\[[^\]]*\]|\{\{|TODO|lorem ipsum|placeholder/i)
    numbers(text).each { |number| found << "the number #{number} isn't in the source" unless stated.include?(number) }
    names(text).each { |name| found << "the name #{name.inspect} isn't in the source" unless allowed_name?(name, source) }
    found << "it has its own link" if text.match?(%r{https?://|www\.}i)
    found << "it has a hashtag" if text.match?(/(^|\s)#\w/)
    found << "it has an emoji" if text.match?(/\p{Extended_Pictographic}/)
    # A date, not relative time: the post may go out days after the event (DQ).
    found << "it says #{$1.downcase.inspect} instead of a date" if text.match(/\b(today|yesterday|tonight|this week|last week|just|now)\b/i)
    if too_long?(text, platform)
      limit = platform == "x" ? X_LIMIT - 2 - X_LINK : LINKEDIN_LIMIT
      found << "it's too long for #{platform == 'x' ? 'X' : 'LinkedIn'} (#{text.length} characters; at most #{limit})"
    end
    found
  end

  # Digits as they'd be written in the source: thousands separators dropped, so 1,404,253 matches 1404253.
  def numbers(text) = text.scan(/\d[\d,.]*\d|\d/).map { |number| number.delete(",").sub(/\.\z/, "") }.uniq

  # Capitalised words (names), each of which must be a word in the source. A sentence may start with a plain word.
  # Words that only start a sentence (shadow day 20 Nov: "Those" was taken for a name).
  OPENERS = %w[Meet Say Introducing According Per The A An It Its This That These Those They Their There Here We Our Both Each Every All Some Most Many
    Several Few Other Another Neither Either Such In On At For With Under After Before By From Since As Over About Across Along Among
    Between During Through Into Upon Within Without While When Where Which Who What Why How If Once Unlike Like Also
    And But Or So Yet Still Meanwhile Separately Together].freeze

  def names(text)
    # A colon opens a clause too: "Meet X: According to ..." (spotlights, #883).
    text.split(/(?<=[.!?:])\s+/).flat_map do |sentence|
      # A possessive is its name: "Power's" checks "Power" (shadow day 20 Nov).
      words = sentence.scan(/[[:alnum:]][\w&'’.-]*[[:alnum:]&]|[[:alnum:]]/).map { |word| word.sub(/['’]s\z/i, "") }.select { |word| word.match?(/[A-Z]/) }
      words.reject.with_index { |word, index| index.zero? && sentence.start_with?(word) && (OPENERS.include?(word) || SocialAgent::Openers.first_words.include?(word)) }
    end.uniq
  end

  def allowed_name?(name, source)
    ALWAYS_ALLOWED.include?(name) || month_written_out?(name, source) || source.match?(/(?<![\w])#{Regexp.escape(normalize(name))}(?![\w])/)
  end

  # "October 2020" for a source's "Oct 2020": a month written out in full is the same month.
  def month_written_out?(name, source)
    index = Date::MONTHNAMES.index(name)
    index && source.match?(/(?<![[:alpha:]])#{Regexp.escape(Date::ABBR_MONTHNAMES[index].downcase)}\b/)
  end

  def too_long?(text, platform)
    platform == "x" ? text.length + 2 + X_LINK > X_LIMIT : text.length > LINKEDIN_LIMIT
  end

  def normalize(text) = text.to_s.downcase.delete(",").tr("’", "'")
end
