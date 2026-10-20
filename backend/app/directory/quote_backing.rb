# Whether a record's own quotes state a value its page shows (#407), so the
# line under its key facts ("About this plant: sources …") may name the fact.
# One rule per field, used by the pages as they're drawn and by the Live
# checks, so the two never disagree:
# - a docket or a legal name: a quote contains it, case, spacing and dash
#   style aside; a docket also in NRC's short forms (05000254 as "50-254"
#   or "050-00254")
# - a place: one quote has the city as written (case and spacing aside) and
#   the state as its two-letter code, its full name or its AP abbreviation
#   ("Tenn.", "N.C.")
# A value counts only as whole words: "Richland" isn't in "Richlands".
#
#   Directory::QuoteBacking.contains?(quotes, "05000254")                # => true
#   Directory::QuoteBacking.place?(quotes, city: "Cordova", state: "IL") # => true
module Directory::QuoteBacking
  # AP style's state abbreviations, as newspapers and press releases write
  # them. States AP spells out (Alaska, Hawaii, Idaho, Iowa, Maine, Ohio,
  # Texas, Utah) have none.
  AP_STATES = {
    "AL" => "Ala.", "AZ" => "Ariz.", "AR" => "Ark.", "CA" => "Calif.", "CO" => "Colo.", "CT" => "Conn.", "DE" => "Del.",
    "DC" => "D.C.", "FL" => "Fla.", "GA" => "Ga.", "IL" => "Ill.", "IN" => "Ind.", "KS" => "Kan.", "KY" => "Ky.", "LA" => "La.",
    "MD" => "Md.", "MA" => "Mass.", "MI" => "Mich.", "MN" => "Minn.", "MS" => "Miss.", "MO" => "Mo.", "MT" => "Mont.",
    "NE" => "Neb.", "NV" => "Nev.", "NH" => "N.H.", "NJ" => "N.J.", "NM" => "N.M.", "NY" => "N.Y.", "NC" => "N.C.",
    "ND" => "N.D.", "OK" => "Okla.", "OR" => "Ore.", "PA" => "Pa.", "RI" => "R.I.", "SC" => "S.C.", "SD" => "S.D.",
    "TN" => "Tenn.", "VT" => "Vt.", "VA" => "Va.", "WA" => "Wash.", "WV" => "W.Va.", "WI" => "Wis.", "WY" => "Wyo."
  }.freeze
  DASHES = "\u2010\u2011\u2012\u2013\u2014\u2015\u2212".freeze

  class << self
    def contains?(quotes, value)
      return false if value.blank?

      pattern = whole(normalize(value))
      quotes.any? { |quote| normalize(quote).match?(pattern) }
    end

    # A docket as stored (05000254) or in NRC's short forms: "50-254",
    # "050-00254", "50-00254".
    def docket?(quotes, docket)
      return true if contains?(quotes, docket)

      prefix, number = docket.to_s[/\A0(\d\d)(\d{5})\z/] && [ ::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i ]
      return false unless number

      short = /(?<![[:alnum:]-])0?#{prefix}-0*#{number}(?![[:alnum:]])/
      quotes.any? { |quote| normalize(quote).match?(short) }
    end

    # Whatever is stored of the two must be in the same quote; nothing stored
    # is nothing to back.
    def place?(quotes, city:, state:)
      return false if city.blank? && state.blank?

      quotes.any? { |quote| (city.blank? || contains?([ quote ], city)) && (state.blank? || state?(quote, state)) }
    end

    private
      # A code is matched in capitals only, so "in" or "or" in a sentence isn't
      # Indiana or Oregon; nor as the end of another state's code ("W.VA.").
      # Virginia's full name doesn't count inside "West Virginia", though
      # another mention in the same quote still does; "West Texas" is Texas.
      def state?(quote, state)
        code, name = names(state.to_s.squish)
        text = normalize(quote)
        (code.present? && quote.to_s.match?(/(?<![[:alnum:].])#{Regexp.escape(code)}(?![[:alnum:]])/)) ||
          (name.present? && text.match?(/(?<![[:alnum:]])#{"(?<!west )" if name.casecmp?("Virginia")}#{Regexp.escape(normalize(name))}(?![[:alnum:]])/)) ||
          ((ap = AP_STATES[code]) && text.match?(/(?<![[:alnum:].])#{Regexp.escape(ap.downcase)}/))
      end

      # [code, full name], either of which may be unknown.
      def names(state)
        return [ state.upcase, LinkCard::US_STATES[state.upcase] ] if LinkCard::US_STATES.key?(state.upcase)

        [ LinkCard::US_STATES.find { |_code, full| full.casecmp?(state) }&.first, state ]
      end

      def normalize(text) = text.to_s.unicode_normalize(:nfkc).tr("‘’", "''").tr(DASHES, "-").squish.downcase

      def whole(text) = /(?<![[:alnum:]])#{Regexp.escape(text)}(?![[:alnum:]])/
  end
end
