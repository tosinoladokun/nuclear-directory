# Which homepage a visit gets in the A/B test (#909): A is today's home, B is search and charts.
#
#   HomeVariant.pick(request, forced: params[:home], bot: bot?) # => #<HomeVariant name="A" forced=false>
#
# Half the visitors get each, decided here on the server, with no cookie (the privacy page promises one cookie, for
# forms). A visitor is a hash of their IP address and browser with a daily salt, the same inputs PostHog's cookieless
# counts use, so one visitor sees one version all day. Nothing is stored: not the IP, the browser or the hash.
#
# The test runs only while HOME_AB_TEST is "on"; otherwise everyone gets A. ?home=a or ?home=b forces a version
# (previews and QA) and the visit is marked forced, so the readout leaves it out. Bots always get A, and anything
# that goes wrong falls back to A.
class HomeVariant
  NAMES = %w[A B].freeze

  attr_reader :name

  def initialize(name, forced: false)
    @name = name
    @forced = forced
  end

  def forced? = @forced
  def b? = name == "B"

  def self.pick(request, forced: nil, bot: false)
    choice = forced.to_s.upcase
    return new(choice, forced: true) if NAMES.include?(choice)
    return new("A") if bot || !enabled?

    new(hash_of(request).getbyte(0).even? ? "A" : "B")
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { feature: "home_variant" })
    new("A")
  end

  def self.enabled? = ENV["HOME_AB_TEST"] == "on"

  # The day is UTC, as PostHog's own daily salt is.
  def self.hash_of(request, day: Time.now.utc.to_date)
    key = Rails.application.key_generator.generate_key("home-variant/#{day.iso8601}", 32)
    OpenSSL::HMAC.digest("SHA256", key, [ request.remote_ip, request.user_agent.to_s ].join("\n"))
  end
end
