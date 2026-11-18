require "test_helper"

# Buffer as the publisher (#769): schedules a post on the platform's channel, cancels it, reads it back. Dummy key.
class SocialAgent::BufferTest < ActiveSupport::TestCase
  setup do
    @saved = ENV["BUFFER_API_KEY"]
    ENV["BUFFER_API_KEY"] = "dummy"
    @requests = []
    @replies = [
      { "data" => { "account" => { "organizations" => [ { "id" => "org1" } ] } } },
      { "data" => { "channels" => [ { "id" => "ch-x", "service" => "twitter" }, { "id" => "ch-li", "service" => "linkedin" } ] } }
    ]
    now = Time.utc(2026, 11, 16, 16, 30)
    @buffer = SocialAgent::Buffer.new(http: ->(request) { @requests << JSON.parse(request.body); @replies.shift }, now: -> { now })
  end

  teardown { @saved ? ENV["BUFFER_API_KEY"] = @saved : ENV.delete("BUFFER_API_KEY") }

  test "a post is scheduled 15 minutes ahead on the platform's channel, with its link" do
    @replies << { "data" => { "createPost" => { "post" => { "id" => "p1", "dueAt" => "2026-11-16T16:45:00Z" } } } }
    sent = @buffer.call("linkedin", "Acme Fission won a DOE award.", "https://nuclear-directory.org/companies/acme")
    assert_equal "p1", sent[:id]
    input = @requests.last["variables"]["input"]
    assert_equal [ "ch-li", "customScheduled", "2026-11-16T16:45:00Z" ], input.values_at("channelId", "mode", "dueAt")
    assert_equal "Acme Fission won a DOE award.\n\nhttps://nuclear-directory.org/companies/acme", input["text"]
  end

  test "Buffer's refusal is a plain failure; a missing key says so" do
    @replies << { "data" => { "createPost" => { "message" => "Daily limit reached" } } }
    assert_raises(SocialAgent::Buffer::Error) { @buffer.call("x", "Text here for the post.", "https://nuclear-directory.org/") }
    ENV.delete("BUFFER_API_KEY")
    error = assert_raises(SocialAgent::Buffer::Error) { SocialAgent::Buffer.new(http: ->(_) { flunk }).call("x", "Text.", "l") }
    assert_match "BUFFER_API_KEY", error.message
  end

  test "cancel deletes the post; status reads it back" do
    @replies.clear
    @replies.push({ "data" => { "deletePost" => { "__typename" => "DeletePostSuccess" } } }, { "data" => { "post" => { "status" => "sent", "externalLink" => "https://x.com/i/1" } } })
    @buffer.cancel("p1")
    assert_equal({ "id" => "p1" }, @requests.last["variables"]["input"])
    assert_equal({ status: "sent", link: "https://x.com/i/1" }, @buffer.status("p1"))
  end
end
