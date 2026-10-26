# A deal row's short "what" (#556, Deals and links): built only from stored
# deal terms, never guessed or cut from a description, under 40 characters.
#
#   award          "$80M ARDP award"
#   funding round  "Anchors $500M Series C-1" ("Anchors" when the company led it)
#   offtake        "5 GW framework by 2039"
#   no term        nil: the row shows name and verb only
#
# A line too long drops its last part (the end year, then the agreement);
# one still too long isn't shown.
module DealLine
  MAX = 40
  AGREEMENTS = { "ppa" => "PPA", "supply_agreement" => "supply agreement", "tariff_subscription" => "tariff subscription",
    "development_agreement" => "development agreement", "prepayment" => "prepayment", "framework" => "framework", "mou" => "MOU",
    "loi" => "letter of intent", "option" => "option", "preorder" => "preorder" }.freeze

  # The line for a link's terms: its newest term that makes one.
  def self.for_terms(terms, company: nil)
    terms.sort_by { |term| [ term.signed_on || term.starts_on || Date.new(1900), term.id.to_i ] }.reverse_each do |term|
      line = self.for(term, company:) and return line
    end
    nil
  end

  def self.for(term, company: nil)
    parts = case term.term_type
    when "award" then [ money(term.amount_usd), term.program.presence, "award" ]
    when "funding_round"
      anchors = "Anchors" if company && Array(term.lead_investor_ids).include?(company.id)
      [ anchors, money(term.amount_usd), term.round.presence || ("round" if term.amount_usd) ]
    when "offtake" then [ capacity(term.capacity_mw), AGREEMENTS[term.agreement.to_s], ending(term) ]
    end
    parts = Array(parts).compact
    return if parts.empty? || parts == [ "award" ] || parts == [ "Anchors" ]

    line = parts.join(" ")
    # Too long: drop the last detail (end year, then agreement), never the amount.
    while line.length > MAX && parts.size > 1
      parts.pop
      line = parts.join(" ")
    end
    # A bare "Anchors" or "award" left after shortening says nothing.
    line if line.length <= MAX && !%w[Anchors award].include?(line)
  end

  # $80M, $1.5B, $750K, $900.
  def self.money(amount)
    return unless amount

    amount = BigDecimal(amount.to_s)
    value, unit = if amount >= 1_000_000_000 then [ amount / 1_000_000_000, "B" ]
    elsif amount >= 1_000_000 then [ amount / 1_000_000, "M" ]
    elsif amount >= 1_000 then [ amount / 1_000, "K" ]
    else [ amount, "" ]
    end
    "$#{trim(value)}#{unit}"
  end

  # 500 MW; 5 GW at 1,000 MW and above.
  def self.capacity(mw)
    return unless mw

    mw = BigDecimal(mw.to_s)
    mw >= 1_000 ? "#{trim(mw / 1_000)} GW" : "#{trim(mw)} MW"
  end

  def self.ending(term)
    if term.ends_on then "by #{term.ends_on.year}"
    elsif term.term_years then "for #{term.term_years} years"
    end
  end

  # One decimal at most, none when whole: 80, 1.5, 4.6.
  def self.trim(value) = value.round(1).to_s("F").delete_suffix(".0")
end
