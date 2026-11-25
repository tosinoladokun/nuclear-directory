require "csv"

# Quotes from the NRC reactor list and the EIA generator file are whole table
# rows, not sentences ("Byron 1 | 05000454 | NPF-37 | PWR | …" or a CSV row
# with float noise like 1224.9000000000001). For display they become labelled
# fields; the exact row stays one tap away, and the stored quote is never
# changed. Any row that doesn't have the expected shape is shown as-is.
module DataQuoteHelper
  # Columns of DataQuality::Plugins::NrcReactorList::Page.lines.
  NRC_KIND = "nrc_reactor_list".freeze
  # Columns of DataQuality::Plugins::EiaGenerators::Workbook::COLUMNS, in order.
  EIA_KIND = "eia_generators".freeze

  # The fields to show for this evidence's quote, or nil to show the quote itself.
  def data_quote_fields(evidence)
    return if evidence.nil? || evidence.quote.blank?

    case evidence.source&.source_kind
    when NRC_KIND then nrc_fields(evidence.quote)
    when EIA_KIND then eia_fields(evidence.quote)
    end
  end

  private
    def nrc_fields(quote)
      cells = quote.split(" | ").map(&:strip)
      return unless cells.size == 7

      name, docket, license, type, location, licensee, region = cells
      [ name, "Docket #{docket}", "License #{license}", type, location, licensee, "NRC region #{region}" ]
    end

    def eia_fields(quote)
      cells = CSV.parse_line(quote) rescue nil
      # A whole stored row ends with its sheet (#916): "Retired sheet".
      return unless [ 11, 12 ].include?(cells&.size)

      plant_id, plant, generator, state, county, summer, nameplate, status, _lat, _lng, entity, sheet = cells.map { |cell| cell.to_s.strip }
      [ "#{plant}, generator #{generator}", "EIA plant #{plant_id}", [ county.presence && "#{county} County", state ].compact.join(", "),
        mw(summer, "net summer"), mw(nameplate, "nameplate"), status.sub(/\A\([A-Z]+\)\s*/, ""), entity,
        ("#{sheet} sheet" if sheet.present?) ].compact_blank
    end

    # "1224.9000000000001" => "1,224.9 MW nameplate"; display only.
    def mw(value, label)
      number = Float(value, exception: false) or return
      "#{number_with_delimiter(number.round(1).to_s.delete_suffix(".0"))} MW #{label}"
    end
end
