require "test_helper"

# #916: a quote states a proposed coordinate as a decimal written as proposed,
# or in degrees, minutes and seconds within the source's own precision.
class DataQuality::CoordinatesTest < ActiveSupport::TestCase
  def stated?(quote, value, axis: "latitude") = DataQuality::Coordinates.stated?(quote, value, axis:)

  test "a decimal as written, or with more digits that round to it, with its sign" do
    row = "68635,Kemmerer Unit 1,1,WY,Lincoln,345,345,(P) Planned,41.705993,-110.5603,TerraPower,Planned"
    assert stated?(row, "41.705993")
    assert stated?(row, "-110.5603", axis: "longitude")
    assert stated?("41.7059934", "41.705993"), "the source has a digit more"
    assert stated?("33.142000000000003", "33.142"), "a spreadsheet's float noise"
    assert_not stated?("41.7059937", "41.705993"), "rounds to 41.705994"
    assert_not stated?("41.70599", "41.705993"), "fewer digits than proposed"
    assert_not stated?("141.705993", "41.705993"), "a whole number, not a tail"
    assert_not stated?("41.705993", "-41.705993"), "the sign must agree"
    assert_not stated?("-110.5603", "110.5603", axis: "longitude")
    assert stated?("The site is at 41.705993.", "41.705993"), "a full stop ends the sentence"
    assert_not stated?("41.705993.5", "41.705993")
  end

  test "a hemisphere letter gives the sign, and only for its own axis" do
    assert stated?("110.5603 W", "-110.5603", axis: "longitude")
    assert stated?("110.5603° W", "-110.5603", axis: "longitude")
    assert stated?("W 110.5603", "-110.5603", axis: "longitude")
    assert stated?("41.705993 N", "41.705993")
    assert_not stated?("41.705993 S", "41.705993")
    assert_not stated?("110.5603 W", "-110.5603"), "W is a longitude, not a latitude"
    assert stated?("-110.5603 W", "-110.5603", axis: "longitude"), "a minus and W agree"
    assert_not stated?("-110.5603 E", "-110.5603", axis: "longitude"), "a minus and E disagree"
    assert_not stated?("-41.705993 N", "-41.705993"), "a minus and N disagree"
    assert stated?("110.5603 west longitude", "-110.5603", axis: "longitude"), "the hemisphere as a word"
    assert_not stated?("41.705993 Northern", "-41.705993"), "a longer word isn't a hemisphere"
    assert_not stated?("41.705993 North", "-41.705993"), "a word isn't a letter, so it's unsigned: positive"
  end

  # Data Quality's real quotes (#916 review on #919).
  test "real sources: degrees and minutes in words with commas, and a minus with W" do
    lost_creek = "It is centered at approximately 42 degrees, 8.06 minutes North latitude and 107 degrees, 51.7 minutes West longitude."
    assert stated?(lost_creek, "42.134333")
    assert stated?(lost_creek, "-107.861667", axis: "longitude")
    assert_not stated?(lost_creek, "-42.134333"), "North gives the sign"
    shirley = "It is centered at approximately 42 degrees, 22 minutes north latitude and 106 degrees, 11 minutes west longitude"
    assert stated?(shirley, "42.366667")
    assert stated?(shirley, "-106.183333", axis: "longitude")
    assert_not stated?(shirley, "106.183333", axis: "longitude"), "west gives the sign"
    dewey = "Project Coordinates: Latitude 43.462° N, Longitude -103.947° W"
    assert stated?(dewey, "43.462")
    assert stated?(dewey, "-103.947", axis: "longitude")
  end

  test "degrees, minutes and seconds, or decimal minutes, within the source's precision" do
    assert stated?(%(37°32'10.49" N), "37.536247")
    assert stated?(%(37° 32′ 10.49″ N), "37.536247"), "typographic marks"
    assert stated?(%(37°32'10" N), "37.536"), "a whole second is about 0.0003 degrees"
    assert_not stated?(%(37°32'10.49" N), "37.537"), "outside a 0.01-second source"
    assert stated?(%(77°19'30" W), "-77.325", axis: "longitude")
    assert_not stated?(%(77°19'30" E), "-77.325", axis: "longitude")
    assert stated?(%(77°19'30"), "-77.325", axis: "longitude"), "no hemisphere: compared without a sign"
    assert stated?(%(37°32.175' N), "37.53625"), "degrees and decimal minutes"
    assert_not stated?(%(37°61'10" N), "38.019"), "61 minutes isn't a minute count"
    assert_not stated?(%(Kemmerer, Wyoming), "41.706")
    assert_not stated?(%(37°32.175' N), "32.175"), "a minute count isn't a latitude"
    assert_not stated?(%(37°32'10.490" W), "10.490"), "nor a second count, on the other axis"
    assert stated?(%(37°32'10.49" N, 41.705993 N), "41.705993"), "a decimal beside a DMS one still counts"
  end
end
