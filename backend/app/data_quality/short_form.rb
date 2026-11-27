# A short form a company's own site uses for it (#998; DQ's trial, 27 Nov):
# "SRP" for Salt River Project. It counts as naming the company only when it
# is the name's initials, in the quote, in the page's own title or site
# name, and at the start of the site's address. Shared by Data Quality's
# pass and the nightly checker, so a website the pass proposes this way can
# be approved by the same rule (Copilot).
#
#   DataQuality::ShortForm.names?(name: "Salt River Project", quote: "SRP | Arizona power",
#     own_names: "SRP | Arizona power", host: "www.srpnet.com") # => true
module DataQuality::ShortForm
  FILLER = %w[of and the for].freeze
  LEGAL_ENDING = /[,\s]+(?:inc|llc|corp|corporation|co|company|ltd|limited)\.?\z/i

  def self.initials(name)
    words = name.to_s.squish.sub(LEGAL_ENDING, "").scan(/[[:alnum:]]+/) - FILLER
    words.map { |word| word[0] }.join.upcase
  end

  def self.names?(name:, quote:, own_names:, host:)
    short = initials(name)
    return false if short.length < 2

    word = /(?<![[:alnum:]])#{short}(?![[:alnum:]])/
    label = host.to_s.downcase.delete_prefix("www.")
    quote.to_s.match?(word) && Array(own_names).join(" ").match?(word) && label.start_with?(short.downcase)
  end
end
