require "net/http"

# Publishes through Buffer (#769, PM 18 Nov): one API key (BUFFER_API_KEY, Render dashboard only) for both the
# LinkedIn Page and X, connected as channels in Buffer's free plan. Each post is scheduled DELAY ahead, so the
# kill switch can still cancel it; a later run reads back whether it went out and its link.
#
# Set up (Tosin): a Buffer account with the X account and the LinkedIn Page connected; Settings › API › new key.
class SocialAgent::Buffer
  ENDPOINT = URI("https://api.buffer.com")
  SERVICES = { "x" => "twitter", "linkedin" => "linkedin" }.freeze
  # Time between handing a post to Buffer and its going out: the window in which the switch can stop it.
  DELAY = 15.minutes
  CREATE = <<~GQL.freeze
    mutation($input: CreatePostInput!) { createPost(input: $input) {
      ... on PostActionSuccess { post { id dueAt } } ... on MutationError { message } } }
  GQL

  class Error < StandardError; end

  def self.configured? = ENV["BUFFER_API_KEY"].present?

  def initialize(http: method(:deliver), now: -> { Time.current })
    @http = http
    @now = now
  end

  # Schedules one post: the text, a blank line, the link. Returns { id:, due_at: }.
  def call(platform, text, link)
    due = @now.call + DELAY
    data = graphql(CREATE, { input: { text: "#{text}\n\n#{link}", channelId: channel_id(platform), schedulingType: "automatic",
      mode: "customScheduled", dueAt: due.utc.iso8601 } })
    result = data.fetch("createPost")
    raise Error, "Buffer said: #{result['message']}" if result["message"]
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
    def channel_id(platform)
      @channels ||= begin
        organization = graphql("query { account { organizations { id } } }").dig("account", "organizations", 0, "id") or raise Error, "Buffer has no organization"
        graphql("query($input: ChannelsInput!) { channels(input: $input) { id service } }", { input: { organizationId: organization } })
          .fetch("channels").to_h { |channel| [ channel["service"], channel["id"] ] }
      end
      @channels[SERVICES.fetch(platform)] or raise Error, "#{platform == 'x' ? 'X' : 'LinkedIn'} isn't connected in Buffer"
    end

    def graphql(query, variables = {})
      raise Error, "Buffer isn't set up: BUFFER_API_KEY on Render" unless self.class.configured?

      request = Net::HTTP::Post.new(ENDPOINT, "Content-Type" => "application/json", "Authorization" => "Bearer #{ENV.fetch('BUFFER_API_KEY')}")
      request.body = { query:, variables: }.to_json
      body = @http.call(request)
      raise Error, "Buffer said: #{Array(body['errors']).map { |error| error['message'] }.to_sentence}" if body["errors"].present?

      body.fetch("data")
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
