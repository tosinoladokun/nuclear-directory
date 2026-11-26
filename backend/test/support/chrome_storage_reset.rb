require "capybara/selenium/driver"
require "capybara/selenium/driver_specializations/chrome_driver"

# Between tests, Capybara 3.40 (the newest) clears cookies with the DevTools
# call Storage.clearDataForOrigin(origin: "*"). Chrome 158 refuses "*"
# ("invalid argument: * is not a valid URL"), so on a CI runner with Chrome
# 158 every system test errored in its teardown (26 Nov, run 45745291186).
# This makes that one call clear every cookie (Network.clearBrowserCookies)
# and clear the requested storage for the test server's own origin, the
# only one the tests visit. Older and newer Chrome both accept it. Drop it
# once Capybara stops sending "*".
module ChromeStorageReset
  private

  def execute_cdp(cmd, params = {})
    return super unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

    super("Network.clearBrowserCookies")
    origin = storage_reset_origin
    super(cmd, params.merge(origin:)) if origin
    nil
  end

  def storage_reset_origin = Capybara.current_session.server&.base_url
end

Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeStorageReset)
