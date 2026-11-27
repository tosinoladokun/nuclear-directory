require "test_helper"

# #998: admin switches. A key with no row is off; only known keys.
class SwitchTest < ActiveSupport::TestCase
  test "off until set, then on, and who changed it is kept" do
    assert_not Switch.on?("dq_pass")
    Switch.set!("dq_pass", true, by: "human:tosin")
    assert Switch.on?("dq_pass")
    assert_equal "human:tosin", Switch.find_by!(key: "dq_pass").changed_by
    Switch.set!("dq_pass", false, by: "human:tosin")
    assert_not Switch.on?("dq_pass")
    assert_equal 1, Switch.count
  end

  test "an unknown key is refused" do
    assert_raises(ActiveRecord::RecordInvalid) { Switch.set!("everything", true, by: "human:tosin") }
  end
end
