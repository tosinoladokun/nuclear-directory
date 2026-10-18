require "application_system_test_case"
require_relative "../support/directory_builders"

# Proves the browser setup works: a page loads with its styles and its
# JavaScript runs.
class SmokeTest < ApplicationSystemTestCase
  include DirectoryBuilders

  test "the home page loads in a browser, styled, and instant search answers" do
    cite!(company("Kairos Power", roles: [ role("reactor_vendor") ]))
    visit root_path

    assert_selector "h1 .sr-only", text: "Nuclear Directory", visible: :all
    assert_equal "flex", page.evaluate_script("getComputedStyle(document.querySelector('.nd-home')).display"), "the stylesheet loaded"

    find("input[name=q]").fill_in(with: "Kairos")
    assert_selector ".nd-searchbox__results a", text: "Kairos Power"
  end

  test "the viewport helpers set the size and colour scheme, and each test starts at 1440x900 light" do
    visit root_path
    assert_equal [ 1440, 900 ], page.evaluate_script("[window.innerWidth, window.innerHeight]")
    assert_not page.evaluate_script("matchMedia('(prefers-color-scheme: dark)').matches")

    resize_viewport(390, 844)
    assert_equal [ 390, 844 ], page.evaluate_script("[window.innerWidth, window.innerHeight]")

    emulate_color_scheme(:dark)
    assert page.evaluate_script("matchMedia('(prefers-color-scheme: dark)').matches")
  end
end
