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
    @buffer = SocialAgent::Buffer.new(http: ->(request) { @requests << JSON.parse(request.body); @replies.shift }, now: -> { now })
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
