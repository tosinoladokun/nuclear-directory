# A deal row's short "what" (#556, Deals and links): built only from stored
# deal terms, never guessed or cut from a description, under 40 characters.
#
#   award          "$80M ARDP award"
#   funding round  "Anchors $500M Series C-1" ("Anchors" when the company led it)
#   offtake        "5 GW framework by 2039"
#   loan           "$1.52B DOE loan" (the lender is the link's funding end)
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
    # A bare assistance-listing number ("81.121") means nothing to a reader: "$1.9M award".
    when "award" then [ money(term.amount_usd), (term.program.presence unless term.program.to_s.match?(/\A\d+\.\d+\z/)), "award" ]
    when "funding_round"
      anchors = "Anchors" if company && Array(term.lead_investor_ids).include?(company.id)
      [ anchors, money(term.amount_usd), term.round.presence || ("round" if term.amount_usd) ]
    when "offtake" then [ capacity(term.capacity_mw), AGREEMENTS[term.agreement.to_s], ending(term) ]
    when "loan" then [ money(term.amount_usd), lender(term), "loan" ]
    end
    parts = Array(parts).compact
    return if parts.empty? || parts == [ "award" ] || parts == [ "Anchors" ] || parts == [ "loan" ]

    # A loan too long drops its lender, never the word "loan".
    parts.delete_at(1) if term.term_type == "loan" && parts.size == 3 && parts.join(" ").length > MAX
    line = parts.join(" ")
    # Too long: drop the last detail (end year, then agreement), never the amount.
    while line.length > MAX && parts.size > 1
      parts.pop
      line = parts.join(" ")
    end
    # A bare "Anchors" or "award" left after shortening says nothing.
    line if line.length <= MAX && !%w[Anchors award loan].include?(line)
  end

  # The lender as a row names it: the link's funding end, by its short name ("DOE").
  def self.lender(term)
    lender = term.try(:link).try(:from_organization) or return
    lender.short_name.presence || lender.name
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
    # Billions keep two decimals ("$1.52B", #582); the rest one.
    "$#{trim(value, unit == "B" ? 2 : 1)}#{unit}"
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

  # Up to `places` decimals, none when whole: 80, 1.5, 1.52.
  def self.trim(value, places = 1) = value.round(places).to_s("F").sub(/\.?0+\z/) { |zeros| zeros.include?(".") ? "" : zeros }
end
