require "test_helper"

# The home page A/B test's split (#909): half and half by a daily hash of IP and browser, no cookie, A by default.
class HomeVariantTest < ActiveSupport::TestCase
  Request = Data.define(:remote_ip, :user_agent)

  def visitor(n, agent: "Mozilla/5.0 Safari") = Request.new(remote_ip: "203.0.113.#{n % 256}", user_agent: "#{agent} #{n / 256}")

  def with_test(value = "on")
    before = ENV["HOME_AB_TEST"]
    ENV["HOME_AB_TEST"] = value
    yield
  ensure
    ENV["HOME_AB_TEST"] = before
  end

  test "off (the default), everyone gets A" do
    with_test(nil) do
      assert_equal %w[A], (0...200).map { |n| HomeVariant.pick(visitor(n)).name }.uniq
    end
  end

  test "on, visitors split about half and half, and one visitor gets the same version all day" do
    with_test do
      names = (0...2000).map { |n| HomeVariant.pick(visitor(n)).name }
      assert_in_delta 1000, names.count("B"), 100, "about half get B"
      assert_equal names.first(50), (0...50).map { |n| HomeVariant.pick(visitor(n)).name }, "the same visitor, the same version"
    end
  end

  test "the hash changes with the day, so it can't follow a visitor from one day to the next" do
    request = visitor(7)
    day = Date.new(2026, 12, 1)
    assert_equal HomeVariant.hash_of(request, day:), HomeVariant.hash_of(request, day:)
    assert_not_equal HomeVariant.hash_of(request, day:), HomeVariant.hash_of(request, day: day + 1)
  end

  test "?home=a or ?home=b forces a version, marked forced, even with the test off" do
    with_test(nil) do
      b = HomeVariant.pick(visitor(1), forced: "b")
      assert_equal [ "B", true ], [ b.name, b.forced? ]
      assert_equal [ "A", true ], [ HomeVariant.pick(visitor(1), forced: "A").name, HomeVariant.pick(visitor(1), forced: "A").forced? ]
      assert_equal [ "A", false ], [ HomeVariant.pick(visitor(1), forced: "c").name, HomeVariant.pick(visitor(1), forced: "c").forced? ]
    end
  end

  test "bots always get A, and anything that goes wrong falls back to A" do
    with_test do
      assert_equal %w[A], (0...100).map { |n| HomeVariant.pick(visitor(n), bot: true).name }.uniq
      broken = Object.new
      def broken.remote_ip = raise("no address")
      assert_equal "A", HomeVariant.pick(broken).name
      assert_not HomeVariant.pick(broken).forced?
    end
  end
end
