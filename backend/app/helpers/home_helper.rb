# Homepage B's chart cards (#909).
module HomeHelper
  # "Sources: nrc.gov, eia.gov and more", from a chart's { domains:, more: }: the real domains behind its facts, at
  # most three (Design, 25 Nov). nil when there are none, so the card shows no source line.
  def chart_sources(sources)
    domains = sources&.dig(:domains).to_a
    return if domains.empty?

    label = domains.size == 1 && !sources[:more] ? "Source" : "Sources"
    list = sources[:more] ? "#{domains.join(", ")} and more" : domains.to_sentence(two_words_connector: " and ", last_word_connector: " and ")
    "#{label}: #{list}"
  end

  # A bar's length, as a share of the longest bar in its chart.
  def chart_bar_width(count, max) = max.to_i.positive? ? (100.0 * count / max).round(1) : 0

  # 45.7 => "45.7%", 30.0 => "30%".
  def chart_pct(pct) = "#{number_with_precision(pct, precision: 1, strip_insignificant_zeros: true)}%"
end
