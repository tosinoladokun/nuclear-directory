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
    assert_not stated?("-110.5603 W", "-110.5603", axis: "longitude"), "two signs"
    assert_not stated?("41.705993 North", "-41.705993"), "a word isn't a letter, so it's unsigned: positive"
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
  end
end
