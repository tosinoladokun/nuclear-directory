# The automated fact check (#769), in code: a draft may use only what its source and facts say. Every number in
# it must appear in them, as must every name (each capitalised word); no link of its own, no hashtag or
# emoji, and it fits the platform. Returns the problems, empty when it passes.
module SocialAgent::Check
  X_LIMIT = 280
  # X counts any link as 23 characters.
  X_LINK = 23
  LINKEDIN_LIMIT = 1_300
  ALWAYS_ALLOWED = [ "Nuclear Directory", "US", "U.S." ].freeze

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
    found << "it's too long for #{platform == 'x' ? 'X' : 'LinkedIn'}" if too_long?(text, platform)
    found
  end

  # Digits as they'd be written in the source: thousands separators dropped, so 1,404,253 matches 1404253.
  def numbers(text) = text.scan(/\d[\d,.]*\d|\d/).map { |number| number.delete(",").sub(/\.\z/, "") }.uniq

  # Capitalised words (names), each of which must be a word in the source. A sentence may start with a plain word.
  OPENERS = %w[The A An It Its This That These In On At For With Under After Before By From Since As].freeze

  def names(text)
    text.split(/(?<=[.!?])\s+/).flat_map do |sentence|
      words = sentence.scan(/[A-Z][\w&'’.-]*[\w&]|[A-Z]/)
      words.reject.with_index { |word, index| index.zero? && sentence.start_with?(word) && OPENERS.include?(word) }
    end.uniq
  end

  def allowed_name?(name, source)
    ALWAYS_ALLOWED.include?(name) || source.match?(/(?<![\w])#{Regexp.escape(normalize(name))}(?![\w])/)
  end

  def too_long?(text, platform)
    platform == "x" ? text.length + 2 + X_LINK > X_LIMIT : text.length > LINKEDIN_LIMIT
  end

  def normalize(text) = text.to_s.downcase.delete(",").tr("’", "'")
end
