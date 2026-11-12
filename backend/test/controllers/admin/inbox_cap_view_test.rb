require "test_helper"

# With today's share used up, the new-companies section stays to say how many wait for tomorrow.
class Admin::InboxCapViewTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:admin) }

  test "nothing left today: the section shows only how many wait" do
    give_sourced_role(Organization.create!(name: "Tomorrow Co", verification_status: "pending"))
    silence_warnings { OwnerInbox.const_set(:CREATES_A_DAY, 0) }
    get admin_inbox_path
    assert_select "#inbox-new_record"
    assert_select "p", /more new compan(y|ies) tomorrow\. 0 a day/
  ensure
    silence_warnings { OwnerInbox.const_set(:CREATES_A_DAY, 10) }
  end
end
