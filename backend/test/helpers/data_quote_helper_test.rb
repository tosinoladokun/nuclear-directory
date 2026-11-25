require "test_helper"

class DataQuoteHelperTest < ActionView::TestCase
  NRC_ROW = "Byron 1 | 05000454 | NPF-37 | PWR | 17 miles SW of Rockford, IL | Constellation Energy Generation, LLC | 3".freeze
  EIA_ROW = "6023,Byron Generating Station,1,IL,Ogle,1164,1224.9000000000001,(OP) Operating,42.0742,-89.2817,Constellation Energy Generation LLC".freeze

  def evidence(quote, kind)
    Evidence.new(quote:, source: Source.new(url: "https://example.org", source_kind: kind))
  end

  test "an NRC reactor list row reads as labelled fields" do
    assert_equal [ "Byron 1", "Docket 05000454", "License NPF-37", "PWR", "17 miles SW of Rockford, IL",
                   "Constellation Energy Generation, LLC", "NRC region 3" ], data_quote_fields(evidence(NRC_ROW, "nrc_reactor_list"))
  end

  test "an EIA generator row reads as labelled fields, with float noise rounded for display" do
    assert_equal [ "Byron Generating Station, generator 1", "EIA plant 6023", "Ogle County, IL", "1,164 MW net summer",
                   "1,224.9 MW nameplate", "Operating", "Constellation Energy Generation LLC" ], data_quote_fields(evidence(EIA_ROW, "eia_generators"))
  end

  test "a whole stored EIA row ends with its sheet (#916), which reads as a field" do
    retired = "8907,Indian Point 2,2,NY,Westchester,1012,1013,,41.2697,-73.9522,Entergy,Retired"
    assert_equal [ "Indian Point 2, generator 2", "EIA plant 8907", "Westchester County, NY", "1,012 MW net summer", "1,013 MW nameplate",
                   "Entergy", "Retired sheet" ], data_quote_fields(evidence(retired, "eia_generators"))
  end

  test "anything else is shown as the quote itself" do
    assert_nil data_quote_fields(evidence("Kairos Power and Google have signed an agreement.", "web_page"))
    assert_nil data_quote_fields(evidence("Byron 1 | 05000454 | NPF-37", "nrc_reactor_list"))
    assert_nil data_quote_fields(evidence("not,a,full,row", "eia_generators"))
    assert_nil data_quote_fields(evidence("", "eia_generators"))
    assert_nil data_quote_fields(nil)
  end
end
