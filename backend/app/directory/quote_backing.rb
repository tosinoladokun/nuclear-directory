# Whether a record's own quotes state a value its page shows (#407), so the
# line under its key facts ("About this plant: sources …") may name the fact.
# One rule per field, used by the pages as they're drawn and by the Live
# checks, so the two never disagree:
# - a docket or a legal name: a quote contains it, case and spacing aside
# - a place: one quote has the city as written (case and spacing aside) and
#   the state as its two-letter code or its full name
# A value counts only as whole words: "Richland" isn't in "Richlands".
#
#   Directory::QuoteBacking.contains?(quotes, "05000254")                # => true
#   Directory::QuoteBacking.place?(quotes, city: "Cordova", state: "IL") # => true
module Directory::QuoteBacking
  class << self
    def contains?(quotes, value)
      return false if value.blank?

      pattern = whole(normalize(value))
      quotes.any? { |quote| normalize(quote).match?(pattern) }
    end

    # Whatever is stored of the two must be in the same quote; nothing stored
    # is nothing to back.
    def place?(quotes, city:, state:)
      return false if city.blank? && state.blank?

      quotes.any? { |quote| (city.blank? || contains?([ quote ], city)) && (state.blank? || state?(quote, state)) }
    end

    private
      # A code is matched in capitals only, so "in" or "or" in a sentence isn't
      # Indiana or Oregon.
      def state?(quote, state)
        code, name = names(state.to_s.squish)
        (code.present? && quote.to_s.match?(whole(code))) || contains?([ quote ], name)
      end

      # [code, full name], either of which may be unknown.
      def names(state)
        return [ state.upcase, LinkCard::US_STATES[state.upcase] ] if LinkCard::US_STATES.key?(state.upcase)

        [ LinkCard::US_STATES.find { |_code, full| full.casecmp?(state) }&.first, state ]
      end

      def normalize(text) = text.to_s.unicode_normalize(:nfkc).tr("‘’", "''").squish.downcase

      def whole(text) = /(?<![[:alnum:]])#{Regexp.escape(text)}(?![[:alnum:]])/
  end
end
