require "test_helper"

# Gems app code uses at run time must be in the Gemfile's default group: test-only
# gems (webmock, capybara) can load them too and hide their absence in production (#932).
class RuntimeGemsTest < ActiveSupport::TestCase
  RUNTIME = %w[public_suffix].freeze

  test "gems the app uses at run time are direct dependencies in the default group" do
    direct = Bundler.definition.dependencies.select { |gem| gem.groups.include?(:default) }.map(&:name)
    RUNTIME.each { |name| assert_includes direct, name, "#{name} must be in the Gemfile's default group" }
  end
end
