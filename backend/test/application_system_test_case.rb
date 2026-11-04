require "test_helper"

# Tests that need a real browser: layout measured on the page (heights,
# overlaps, scrolling) and JavaScript (#362, #363). Headless Chrome, which
# the CI runners already have. Run with `bin/rails test:system`;
# `bin/rails test` leaves them out.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # In Docker on an ARM Mac there's no Chrome for Testing: install Debian's
  # chromium and chromium-driver and point these at them. CI needs neither.
  Selenium::WebDriver::Chrome::Service.driver_path = ENV["CHROMEDRIVER_PATH"] if ENV["CHROMEDRIVER_PATH"]

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1440, 900 ] do |options|
    options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"]
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox") # needed in containers
    options.add_argument("--force-color-profile=srgb")
  end

  # Every test starts on a 1440x900 viewport in light mode: the browser is
  # reused between tests and keeps whatever size and scheme the last one set.
  # The reused browser also keeps its HTTP cache: the search index is cached for ten minutes, and a test's records
  # aren't the last test's (#696).
  setup do
    page.driver.browser.execute_cdp("Network.clearBrowserCache")
    resize_viewport(1440, 900)
    emulate_color_scheme(:light)
  end

  # Resizes the window so the page's viewport (not the window) is width x height.
  def resize_viewport(width, height)
    page.driver.browser.manage.window.resize_to(width, height)
    inner = page.evaluate_script("[window.innerWidth, window.innerHeight]")
    page.driver.browser.manage.window.resize_to(2 * width - inner[0], 2 * height - inner[1])
  end

  # Light or dark, as the visitor's system setting would choose it.
  def emulate_color_scheme(scheme)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme.to_s } ])
  end
end
