require "net/http"

# Publishes through Buffer (#769, PM 18 Nov): one API key (BUFFER_API_KEY, Render dashboard only) for both the
# LinkedIn Page and X, connected as channels in Buffer's free plan. Each post is scheduled DELAY ahead, so the
# kill switch can still cancel it; a later run reads back whether it went out and its link.
#
# Set up (Tosin): a Buffer account with only the X account and the LinkedIn Page connected; Settings › API › new key
# as BUFFER_API_KEY; each channel's id as BUFFER_X_CHANNEL_ID and BUFFER_LINKEDIN_CHANNEL_ID (Infra sets them).
class SocialAgent::Buffer
  ENDPOINT = URI("https://api.buffer.com")
  CHANNEL_KEYS = { "x" => "BUFFER_X_CHANNEL_ID", "linkedin" => "BUFFER_LINKEDIN_CHANNEL_ID" }.freeze
  # Time between handing a post to Buffer and its going out: the window in which the switch can stop it.
  DELAY = 15.minutes
  CREATE = <<~GQL.freeze
    mutation($input: CreatePostInput!) { createPost(input: $input) {
      ... on PostActionSuccess { post { id dueAt } } ... on MutationError { message } } }
  GQL

  class Error < StandardError; end

  # Buffer Free allows 1,000 requests a channel per 30 days (2 channels: 2,000); we stop at 80% and say so (PM).
  MONTHLY_REQUESTS = ENV.fetch("BUFFER_MONTHLY_REQUESTS", "2000").to_i
  ALERT_AT = 0.8
  # Requests a post costs at most: create, a read or two, a cancel (Infra). Counted from the posts table, which keeps
  # them (the cache keeps a day).
  PER_POST = 4

  def self.requests_last_30_days(now: Time.current) = SocialPost.where.not(external_id: nil).where(created_at: (now - 30.days)..).count * PER_POST
  def self.budget_spent? = requests_last_30_days >= MONTHLY_REQUESTS * ALERT_AT

  def self.configured? = ENV["BUFFER_API_KEY"].present? && CHANNEL_KEYS.values.all? { |key| ENV[key].present? }

  def initialize(http: method(:deliver), now: -> { Time.current }, card: method(:page_card))
    @http = http
    @now = now
    @card = card
  end

  # Schedules one post. Returns { id:, due_at: }.
  # LinkedIn only draws a preview card for a link attachment, not for a URL in the text (PM, 21 Nov: the first live post had none): the
  # attachment carries our page's own title, description and card image, and the text then has no raw URL. X builds its card from the
  # URL in the text (its metadata has no link attachment). When the page can't be read, the URL stays in the text, so the post still goes.
  def call(platform, text, link)
    due = @now.call + DELAY
    card = @card.call(link) if platform == "linkedin"
    input = { text: card ? text : "#{text}\n\n#{link}", channelId: channel_id(platform), schedulingType: "automatic", mode: "customScheduled", dueAt: due.utc.iso8601 }
    input[:metadata] = { linkedin: { linkAttachment: card } } if card
    result =
      begin
        create(input)
      rescue Error
        # Buffer refused the request (a refusal means nothing was created, so a retry can't double-post; a timeout or odd reply is
        # Uncertain and never retried). When the attachment may be why, the post goes with the URL in its text instead (Infra, Backend).
        raise unless card

        create(input.except(:metadata).merge(text: "#{text}\n\n#{link}"))
      end
    id = result.dig("post", "id") or raise SocialAgent::Uncertain, "Buffer didn't return the post's id"
    { id:, due_at: Time.zone.parse(result.dig("post", "dueAt").to_s) || due }
  end

  # Takes a scheduled post back out of Buffer (the kill switch).
  def cancel(id) = graphql("mutation($input: DeletePostInput!) { deletePost(input: $input) { __typename } }", { input: { id: } })

  # Whether it went out: { status: "sent" | "error" | other, link: }.
  def status(id)
    post = graphql("query($input: PostInput!) { post(input: $input) { status externalLink } }", { input: { id: } }).fetch("post")
    { status: post["status"], link: post["externalLink"] }
  end

  private
    def create(input)
      result = graphql(CREATE, { input: })["createPost"] or raise SocialAgent::Uncertain, "Buffer's reply had no createPost"
      raise Error, "Buffer said: #{result['message']}" if result["message"]

      result
    end

    # Our page's own link preview, read from its og tags: { url:, title:, description:, thumbnail: { url: } }, or nil.
    def page_card(link)
      uri = URI(link)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |http| http.get(uri.request_uri, "User-Agent" => DataQuality::Fetcher::USER_AGENT) }
      return unless response.is_a?(Net::HTTPSuccess)

      doc = Nokogiri::HTML(response.body.to_s)
      og = ->(name) { doc.at_css(%(meta[property="og:#{name}"]))&.[]("content").to_s.squish.presence }
      title, image = og.("title"), og.("image")
      return unless title && image

      { url: link, title:, description: og.("description"), thumbnail: { url: image } }.compact
    rescue StandardError
      nil
    end

    # The brand channels by their Buffer ids (Infra): never found by service, so a personal profile or a second
    # account on the same Buffer login can't get the post.
    def channel_id(platform) = ENV[CHANNEL_KEYS.fetch(platform)].presence || raise(Error, "#{CHANNEL_KEYS.fetch(platform)} isn't set on Render")

    def graphql(query, variables = {})
      raise Error, "Buffer isn't set up: BUFFER_API_KEY on Render" if ENV["BUFFER_API_KEY"].blank?

      request = Net::HTTP::Post.new(ENDPOINT, "Content-Type" => "application/json", "Authorization" => "Bearer #{ENV.fetch('BUFFER_API_KEY')}")
      request.body = { query:, variables: }.to_json
      body = @http.call(request)
      raise Error, "Buffer said: #{Array(body['errors']).map { |error| error['message'] }.to_sentence}" if body["errors"].present?

      body["data"] or raise SocialAgent::Uncertain, "Buffer's reply had no data"
    end

    def deliver(request)
      response = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
      code = response.code.to_i
      raise Error, "Buffer said #{code}: #{response.body.to_s.truncate(200)}" if code.between?(400, 499) && code != 429
      raise SocialAgent::Uncertain, "Buffer said #{code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise SocialAgent::Uncertain, "Buffer's reply wasn't readable"
    rescue Net::OpenTimeout => error
      raise Error, "couldn't reach Buffer (#{error.class}), nothing sent"
    rescue Net::ReadTimeout, EOFError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => error
      raise SocialAgent::Uncertain, error.class.name
    end
end
