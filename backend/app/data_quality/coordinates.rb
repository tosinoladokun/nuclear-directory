# Whether a quote states a coordinate Data Quality proposes for a site (#916).
#
#   DataQuality::Coordinates.stated?("Latitude 41.705993, Longitude -110.5603", "-110.5603", axis: "longitude") # => true
#
# Two ways a source may write it:
# - A decimal, as proposed: the same digits, or more digits that round to it
#   (41.7059934 states 41.705993), with the same sign. A minus sign or the
#   hemisphere letter (110.5603 W) gives the sign; neither means positive.
# - Degrees, minutes and seconds (37°32'10.49" N) or degrees and decimal
#   minutes (37°32.175' N): converted, and the proposed value must be within
#   the source's own precision (half its last digit) plus the proposal's
#   rounding. A hemisphere letter or minus sign must agree; with neither,
#   the degrees are compared without a sign.
# A letter for the other axis (N or S for a longitude) is never this axis.
module DataQuality::Coordinates
  HEMISPHERES = { "latitude" => { "N" => 1, "S" => -1 }, "longitude" => { "E" => 1, "W" => -1 } }.freeze
  MINUS = "[-−]"
  HEMI = "[NSEW](?![A-Za-z])"
  PRE = "(?:(?<![A-Za-z])(?<pre>[NSEW])\\s*)?"
  POST = "\\s*°?\\s*(?<post>#{HEMI})?"
  # A number on its own: not the tail of a longer one, and a full stop after it ends a sentence.
  DECIMAL = /#{PRE}(?<!\d)(?<!\d\.)(?<sign>#{MINUS})?(?<number>\d{1,3}\.\d+)(?!\.?\d)#{POST}/
  DEGREE = "(?:°|º|˚|\\s*deg(?:rees)?\\.?)"
  MINUTE = "(?:'|′|’|‘|\\s*min\\.?)"
  SECOND = "(?:\"|″|”|“|''|′′|’’|\\s*sec\\.?)"
  DMS = /#{PRE}(?<!\d)(?<!\d\.)(?<sign>#{MINUS})?(?<deg>\d{1,3})\s*#{DEGREE}\s*(?<min>\d{1,2}(?:\.\d+)?)\s*#{MINUTE}\s*(?:(?<sec>\d{1,2}(?:\.\d+)?)\s*#{SECOND})?\s*(?<post>#{HEMI})?/

  # value: the proposed decimal, as a string ("-110.5603"). axis: "latitude" or "longitude".
  def self.stated?(quote, value, axis:)
    proposed = BigDecimal(value)
    places = value[/\.(\d+)\z/, 1].to_s.size
    decimal?(quote.to_s, proposed, places, axis) || dms?(quote.to_s, proposed, places, axis)
  end

  # Degrees, minutes and seconds are read whole by dms?, never their minutes or seconds as a decimal (Copilot).
  def self.decimal?(quote, proposed, places, axis)
    quote.gsub(DMS, " ").to_enum(:scan, DECIMAL).map { Regexp.last_match }.any? do |match|
      sign = sign_of(match, axis) or next false
      written = match[:number]
      next false if written[/\.(\d+)\z/, 1].size < places

      sign == (proposed.negative? ? -1 : 1) && BigDecimal(written).round(places) == proposed.abs
    end
  end

  def self.dms?(quote, proposed, places, axis)
    quote.to_enum(:scan, DMS).map { Regexp.last_match }.any? do |match|
      sign = sign_of(match, axis, unsigned: 0) or next false
      next false if sign.nonzero? && sign != (proposed.negative? ? -1 : 1)

      minutes, seconds = BigDecimal(match[:min]), match[:sec] && BigDecimal(match[:sec])
      next false if minutes >= 60 || seconds.to_i >= 60 || (seconds && match[:min].include?("."))

      degrees = BigDecimal(match[:deg]) + minutes / 60 + (seconds || 0) / 3600
      # Half the last digit the source wrote, in degrees, plus the proposal's own rounding.
      last = seconds ? match[:sec] : match[:min]
      precision = BigDecimal("0.5") * BigDecimal(10)**-last[/\.(\d+)\z/, 1].to_s.size / (seconds ? 3600 : 60)
      (degrees - proposed.abs).abs <= precision + BigDecimal("0.5") * BigDecimal(10)**-places
    end
  end

  # +1 or -1 from a minus sign or a hemisphere letter of this axis; unsigned when it has neither; nil when a
  # letter names the other axis, or two signs disagree.
  def self.sign_of(match, axis, unsigned: 1)
    letters = [ match[:pre], match[:post] ].compact
    return if letters.size > 1 || letters.any? { |letter| !HEMISPHERES.fetch(axis).key?(letter) }

    minus = match[:sign].present?
    return if letters.any? && minus
    return HEMISPHERES.fetch(axis).fetch(letters.first) if letters.any?

    minus ? -1 : unsigned
  end
  private_class_method :decimal?, :dms?, :sign_of
end
