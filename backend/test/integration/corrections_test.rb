require "test_helper"
require_relative "../support/directory_builders"

class CorrectionsTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup { CorrectionsController::RATE_LIMIT_STORE.clear }

  test "the form is prefilled with the fact and page it came from" do
    get new_correction_path(subject: "Google offtakes from Kairos Power", page: "/companies/kairos-power")

    assert_response :success
    assert_select "main", 1
    assert_select "h1", "Report a correction"
    assert_select ".nd-about dd", /Google offtakes from Kairos Power/
    assert_select ".nd-about a[href='/companies/kairos-power']", "Back to the page"
    assert_select "input[type=hidden][name=subject][value='Google offtakes from Kairos Power']"
    assert_select "textarea#correction-message[required][aria-describedby='correction-message-hint']"
    assert_select "label[for=correction-message]", "What should change?"
    assert_select "a[href^='mailto:hello@nuclear-directory.org?']"
  end

  test "a company with an ampersand in its name shows it as text on its deal row (the page's one correction link is the quiet line's)" do
    kairos = company("Kairos Power")
    cite!(link(company("Sargent & Lundy"), "supplies", kairos))
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow__who", text: "Sargent & Lundy supplies Kairos Power"
    assert_select ".nd-crow a[href^='/corrections/new']", 0, "no Report a correction per row (removed 25 Oct)"
  end

  test "the form leaves validation to the server, so its error summary shows" do
    get new_correction_path(subject: "x", page: "/")

    assert_select "form.nd-form[novalidate]"
    assert_select "textarea#correction-message[required]"
  end

  test "a page outside the site is never linked" do
    [ "//evil.example/phish", "/\\evil.example/phish", "https://evil.example", "/ok\\..\\x" ].each do |page|
      get new_correction_path(subject: "Something", page:)

      assert_select "input[name=page_path][value='/']"
      assert_select ".nd-about a", count: 0
    end

    post corrections_path, params: { subject: "x", page_path: "/\\evil.example/phish", message: "m" }
    assert_redirected_to correction_sent_path(page: "/")
    assert_equal "/", CorrectionReport.last.page_path
  end

  test "sending saves an open report, without any IP, and confirms" do
    plant("Plant Vogtle")
    assert_difference "CorrectionReport.count", 1 do
      post corrections_path, params: { subject: "Plant Vogtle", page_path: "/plants/plant-vogtle", message: "Unit 4 started in 2024.", contact: "a@example.com" }
    end

    report = CorrectionReport.last
    assert_equal [ "Plant Vogtle", "/plants/plant-vogtle", "Unit 4 started in 2024.", "a@example.com", "open" ],
      report.values_at(:subject, :page_path, :message, :contact, :status)
    assert_not CorrectionReport.column_names.any? { |column| column.match?(/ip|agent/i) }

    assert_redirected_to correction_sent_path(page: "/plants/plant-vogtle")
    follow_redirect!
    assert_select "h1", "Correction sent"
    assert_select "[role=status]", /We'll review it against the source./
    assert_select "a[href='/plants/plant-vogtle']", "Back to Plant Vogtle", "back names the page the correction was about"
  end

  test "the sent page goes back to the page it was about: a company, a list, an unknown page, or search" do
    company("Kairos Power")
    get correction_sent_path(page: "/companies/kairos-power")
    assert_select "a[href='/companies/kairos-power']", "Back to Kairos Power"

    get correction_sent_path(page: "/companies?category=fuel")
    assert_select "a[href=?]", "/companies?category=fuel", "Back to the list"

    get correction_sent_path(page: "/companies/kairos-power?ref=x#deals")
    assert_select "a[href=?]", "/companies/kairos-power?ref=x#deals", "Back to Kairos Power", "the query and fragment are kept and don't hide the record"

    company("Hidden Co", verified: false)
    get correction_sent_path(page: "/companies/hidden-co")
    assert_select "a[href='/companies/hidden-co']", "Back to the page", "an unpublished record's name isn't shown"
    assert_select "body", text: /Hidden Co/, count: 0

    get correction_sent_path(page: "/companies/missing")
    assert_select "a[href='/companies/missing']", "Back to the page", "only the list itself is 'the list'"

    get correction_sent_path(page: "/about")
    assert_select "a[href='/about']", "Back to the page"

    get correction_sent_path(page: "/")
    assert_select "a[href='/']", "Back to search"

    get correction_sent_path(page: "//evil.example")
    assert_select "a[href='/']", "Back to search", "only paths on this site"
  end

  test "an empty message is sent back with an error that says how to fix it" do
    assert_no_difference "CorrectionReport.count" do
      post corrections_path, params: { subject: "Plant Vogtle", page_path: "/plants/plant-vogtle", message: " ", contact: "not-an-email" }
    end

    assert_response :unprocessable_entity
    assert_select ".nd-alert[role=alert] a[href='#correction-message']", "Say what should change before sending."
    assert_select "textarea#correction-message[aria-invalid=true][aria-describedby='correction-message-hint correction-message-error']"
    assert_select "#correction-contact-error", "Enter an email like name@example.com, or leave it empty."
    assert_select "input#correction-contact[value='not-an-email']"
  end

  test "a filled honeypot looks like success but saves nothing" do
    assert_no_difference "CorrectionReport.count" do
      post corrections_path, params: { subject: "x", page_path: "/", message: "spam", website: "http://spam.example" }
    end
    assert_redirected_to correction_sent_path(page: "/")
  end

  test "too many reports in a few minutes are refused" do
    CorrectionsController::RATE_LIMIT.times do
      post corrections_path, params: { subject: "x", page_path: "/", message: "m" }
    end

    assert_no_difference "CorrectionReport.count" do
      post corrections_path, params: { subject: "x", page_path: "/", message: "m" }
    end
    assert_response :too_many_requests
    assert_select ".nd-alert[role=alert]", /Wait a few minutes/
  end

  test "a company page has one Report a correction, in the quiet line, with the page as its subject" do
    kairos = company("Kairos Power")
    cite!(link(company("Google"), "offtake_with", kairos))
    get company_path(slug: "kairos-power")

    assert_select "a[href^='/corrections/new']", 1
    assert_select ".nd-quiet a[href=?]", new_correction_path(subject: "Kairos Power", page: "/companies/kairos-power"), text: "Report a correction"
  end

  test "a plant page has one Report a correction, in the quiet line, with the plant as its subject" do
    vogtle = cite!(plant("Plant Vogtle", facility_type: "power_reactor"))
    cite!(link(company("Georgia Power"), "owns", vogtle))
    get plant_path(slug: "plant-vogtle")

    assert_select "a[href^='/corrections/new']", 1
    assert_select ".nd-quiet a[href=?]", new_correction_path(subject: "Plant Vogtle", page: "/plants/plant-vogtle"), text: "Report a correction"
  end
end
