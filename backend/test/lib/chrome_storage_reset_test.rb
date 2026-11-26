require "test_helper"
require_relative "../support/chrome_storage_reset"

# The system tests' fix for Chrome 158 refusing origin "*" (support/chrome_storage_reset.rb),
# checked on a stand-in driver, so it runs without a browser.
class ChromeStorageResetTest < ActiveSupport::TestCase
  class FakeDriver
    attr_reader :calls
    def initialize = @calls = []
    def reset = execute_cdp("Storage.clearDataForOrigin", origin: "*", storageTypes: "cookies,local_storage")
    def other = execute_cdp("Network.clearBrowserCache")

    private

    def execute_cdp(cmd, params = {}) = @calls << [ cmd, params ]
  end
  FakeDriver.prepend(ChromeStorageReset)
  # The test server's origin, which a real session reads from Capybara.
  FakeDriver.prepend(Module.new { private def storage_reset_origin = "http://127.0.0.1:4567" })

  test "Capybara's every-origin clear becomes all cookies plus the test server's origin" do
    driver = FakeDriver.new
    driver.reset

    assert_equal [ [ "Network.clearBrowserCookies", {} ],
      [ "Storage.clearDataForOrigin", { origin: "http://127.0.0.1:4567", storageTypes: "cookies,local_storage" } ] ], driver.calls
  end

  test "every other DevTools call passes through unchanged" do
    driver = FakeDriver.new
    driver.other
    assert_equal [ [ "Network.clearBrowserCache", {} ] ], driver.calls
  end

  test "it's in place on Capybara's Chrome driver" do
    assert_includes Capybara::Selenium::Driver::ChromeDriver.ancestors, ChromeStorageReset
  end
end
