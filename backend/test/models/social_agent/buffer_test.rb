require "test_helper"

# Buffer as the publisher (#769): schedules a post on the platform's channel, cancels it, reads it back. Dummy key.
class SocialAgent::BufferTest < ActiveSupport::TestCase
  KEYS = { "BUFFER_API_KEY" => "dummy", "BUFFER_X_CHANNEL_ID" => "ch-x", "BUFFER_LINKEDIN_CHANNEL_ID" => "ch-li" }.freeze

  setup do
    @saved = ENV.to_h.slice(*KEYS.keys)
    ENV.update(KEYS)
    @requests = []
    @replies = []
    now = Time.utc(2026, 11, 16, 16, 30)
    @buffer = SocialAgent::Buffer.new(http: ->(request) { @requests << JSON.parse(request.body); @replies.shift }, now: -> { now }, card: ->(_) { nil })
  end

  teardown { KEYS.each_key { |key| @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key) } }

  test "a post is scheduled 15 minutes ahead on the platform's channel, with its link" do
    @replies << { "data" => { "createPost" => { "post" => { "id" => "p1", "dueAt" => "2026-11-16T16:45:00Z" } } } }
    sent = @buffer.call("linkedin", "Acme Fission won a DOE award.", "https://nuclear-directory.org/companies/acme")
    assert_equal "p1", sent[:id]
    input = @requests.last["variables"]["input"]
    assert_equal [ "ch-li", "customScheduled", "2026-11-16T16:45:00Z" ], input.values_at("channelId", "mode", "dueAt")
    assert_equal "Acme Fission won a DOE award.\n\nhttps://nuclear-directory.org/companies/acme", input["text"]
  end

  test "LinkedIn gets our page as a link attachment (title, description, card image) and no raw URL; X keeps the URL in its text; a page that can't be read keeps the URL (PM, 21 Nov)" do
    card = { url: "https://nuclear-directory.org/companies/acme?utm_source=linkedin", title: "Acme Fission | Nuclear Directory", description: "Acme designs reactors.", thumbnail: { url: "https://nuclear-directory.org/cards/companies/acme/abc.png" } }
    with_card = SocialAgent::Buffer.new(http: ->(request) { @requests << JSON.parse(request.body); @replies.shift }, now: -> { Time.utc(2026, 11, 16, 16, 30) }, card: ->(_link) { card })
    2.times { @replies << { "data" => { "createPost" => { "post" => { "id" => "p1", "dueAt" => "2026-11-16T16:45:00Z" } } } } }
    with_card.call("linkedin", "Meet Acme Fission.", card[:url])
    input = @requests.last["variables"]["input"]
    assert_equal "Meet Acme Fission.", input["text"], "no URL in the text: the card is the link"
    assert_equal({ "url" => card[:url], "title" => card[:title], "description" => card[:description], "thumbnail" => { "url" => card[:thumbnail][:url] } }, input.dig("metadata", "linkedin", "linkAttachment"))

    with_card.call("x", "Meet Acme Fission.", card[:url])
    input = @requests.last["variables"]["input"]
    assert_equal "Meet Acme Fission.\n\n#{card[:url]}", input["text"]
    assert_nil input["metadata"], "X has no link attachment: its card comes from the URL in the text"

    @replies << { "data" => { "createPost" => { "post" => { "id" => "p2", "dueAt" => "2026-11-16T16:45:00Z" } } } }
    @buffer.call("linkedin", "Meet Acme Fission.", card[:url])
    assert_equal "Meet Acme Fission.\n\n#{card[:url]}", @requests.last["variables"]["input"]["text"], "page unreadable: the URL stays in the text"
    assert_nil @requests.last["variables"]["input"]["metadata"]
  end

  test "when Buffer refuses the LinkedIn attachment, the post goes once more with the URL in its text; an uncertain reply is never retried" do
    card = { url: "https://nuclear-directory.org/companies/acme", title: "Acme", thumbnail: { url: "https://nuclear-directory.org/c.png" } }
    with_card = SocialAgent::Buffer.new(http: ->(request) { @requests << JSON.parse(request.body); @replies.shift }, now: -> { Time.utc(2026, 11, 16, 16, 30) }, card: ->(_) { card })
    @replies << { "data" => { "createPost" => { "message" => "Invalid link attachment" } } }
    @replies << { "data" => { "createPost" => { "post" => { "id" => "p9", "dueAt" => "2026-11-16T16:45:00Z" } } } }
    assert_equal "p9", with_card.call("linkedin", "Meet Acme.", card[:url])[:id]
    assert_equal 2, @requests.size
    assert_equal "Meet Acme.\n\n#{card[:url]}", @requests.last["variables"]["input"]["text"]
    assert_nil @requests.last["variables"]["input"]["metadata"]

    @requests.clear
    @replies << { "data" => {} }
    assert_raises(SocialAgent::Uncertain) { with_card.call("linkedin", "Meet Acme.", card[:url]) }
    assert_equal 1, @requests.size, "never retried when it may have gone out"
    @requests.clear
    @replies << { "data" => { "createPost" => { "message" => "Daily limit reached" } } }
    @replies << { "data" => { "createPost" => { "message" => "Daily limit reached" } } }
    assert_raises(SocialAgent::Buffer::Error) { with_card.call("linkedin", "Meet Acme.", card[:url]) }
  end

  test "the card fetch identifies itself as NuclearDirectoryBot, so it counts as a bot and not a pageview (Infra)" do
    agent = nil
    stub = Net::HTTP.singleton_class
    original = Net::HTTP.method(:start)
    stub.send(:define_method, :start) do |*_args, **_opts, &block|
      http = Object.new
      http.define_singleton_method(:get) { |_path, headers| agent = headers["User-Agent"]; Net::HTTPNotFound.new("1.1", "404", "Not Found") }
      block.call(http)
    end
    SocialAgent::Buffer.new.send(:page_card, "https://nuclear-directory.org/companies/acme")
    assert_match(/\ANuclearDirectoryBot\//, agent)
  ensure
    stub.send(:define_method, :start, original) if original
  end

  test "a channel without its id set on Render isn't posted to; an odd reply after sending is 'may have gone out'" do
    ENV.delete("BUFFER_X_CHANNEL_ID")
    error = assert_raises(SocialAgent::Buffer::Error) { @buffer.call("x", "Text here for the post.", "l") }
    assert_equal "BUFFER_X_CHANNEL_ID isn't set on Render", error.message
    assert_empty @requests, "nothing sent"
    @replies << { "data" => {} }
    assert_raises(SocialAgent::Uncertain) { @buffer.call("linkedin", "Text here for the post.", "l") }
  end

  test "Buffer's refusal is a plain failure; a missing key says so" do
    @replies << { "data" => { "createPost" => { "message" => "Daily limit reached" } } }
    assert_raises(SocialAgent::Buffer::Error) { @buffer.call("x", "Text here for the post.", "https://nuclear-directory.org/") }
    ENV.delete("BUFFER_API_KEY")
    error = assert_raises(SocialAgent::Buffer::Error) { SocialAgent::Buffer.new(http: ->(_) { flunk }).call("x", "Text.", "l") }
    assert_match "BUFFER_API_KEY", error.message
  end

  test "cancel deletes the post; status reads it back" do
    @replies.push({ "data" => { "deletePost" => { "__typename" => "DeletePostSuccess" } } }, { "data" => { "post" => { "status" => "sent", "externalLink" => "https://x.com/i/1" } } })
    @buffer.cancel("p1")
    assert_equal({ "id" => "p1" }, @requests.last["variables"]["input"])
    assert_equal({ status: "sent", link: "https://x.com/i/1" }, @buffer.status("p1"))
  end
end
