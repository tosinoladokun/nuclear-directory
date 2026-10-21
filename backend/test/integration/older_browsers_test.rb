require "test_helper"

# A public directory turns no reader away: older browsers get the pages too.
class OlderBrowsersTest < ActionDispatch::IntegrationTest
  SAFARI_17_0 = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1".freeze
  CHROME_109 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36".freeze

  test "Safari 17.0 and an older Chrome get the home page, a company page and robots.txt" do
    company = Organization.create!(name: "Imaginary Fission", verification_status: "verified", verified_by: "human:tosin")
    Evidence.create!(subject: company, source: sources(:press_release), quote: "Imaginary Fission", found_by: "human")

    [ SAFARI_17_0, CHROME_109 ].each do |agent|
      [ root_path, company_path(slug: company.slug), robots_path ].each do |path|
        get path, headers: { "User-Agent" => agent }
        assert_response :success, "#{path} for #{agent[/(Version|Chrome)\/[\d.]+/]}"
      end
    end
  end
end
