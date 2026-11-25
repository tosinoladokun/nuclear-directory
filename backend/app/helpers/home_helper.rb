# Homepage B's chart cards (#909).
module HomeHelper
  # The longest card title that fits on one line at 17px in a 320px phone's card.
  PHONE_TITLE_FITS = 26

  # "Sources: nrc.gov, eia.gov and more", from a chart's { domains:, more: }: the real domains behind its facts, at
  # most three on a large card and two on a small one (Design, 25 Nov). nil when there are none: no source line.
  def chart_sources(sources, limit: 3)
    all = sources&.dig(:domains).to_a
    return if all.empty?

    domains = all.first(limit)
    sources = sources.merge(more: sources[:more] || all.size > limit)

    label = domains.size == 1 && !sources[:more] ? "Source" : "Sources"
    list = sources[:more] ? "#{domains.join(", ")} and more" : domains.to_sentence(two_words_connector: " and ", last_word_connector: " and ")
    "#{label}: #{list}"
  end

  # How a chart names a company: its short name when it has one ("Southern Nuclear", not "Southern Nuclear Operating
  # Co., Inc."; PM, #909), else its name. The full name goes in the title.
  def chart_name(row) = row[:short].presence || row[:name]

  # A bar's length, as a share of the longest bar in its chart.
  def chart_bar_width(count, max) = max.to_i.positive? ? (100.0 * count / max).round(1) : 0

  # 45.7 => "45.7%", 30.0 => "30.0%": every share with one decimal, so they line up (Design, #920).
  def chart_pct(pct) = "#{number_with_precision(pct, precision: 1)}%"
end
