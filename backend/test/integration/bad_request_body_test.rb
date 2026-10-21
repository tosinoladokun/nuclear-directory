require "test_helper"

# Scanners POST malformed bodies (18 Oct: a multipart body with a boundary
# Rack refuses raised Rack::Multipart::BoundaryTooLongError as a 500 and a
# Sentry alert). Sent raw through the whole app, as a scanner sends them.
class BadRequestBodyTest < ActiveSupport::TestCase
  # Rack refuses a multipart boundary longer than 70 characters
  # (Rack::Multipart::Parser). At or under that limit a different error comes
  # out, one Rack's own method-override step swallows, so this is the case
  # the middleware has to catch.
  TOO_LONG_BOUNDARY = "x" * 71

  def post_raw(content_type, body, **env)
    Rack::MockRequest.new(Rails.application).post("/", "CONTENT_TYPE" => content_type, "HTTP_HOST" => "www.example.com", input: body, **env)
  end

  test "a multipart POST with a boundary Rack refuses gets a 400" do
    response = post_raw("multipart/form-data; boundary=#{TOO_LONG_BOUNDARY}", "a" * 20_000)
    assert_equal 400, response.status
    assert_equal "Bad request\n", response.body
  end

  test "a multipart POST that ends early is not a 500" do
    response = post_raw("multipart/form-data; boundary=abc", "a" * 20_000)
    assert_not_equal 500, response.status
  end

  test "the middleware sits above Rack::MethodOverride, which parses POST bodies" do
    stack = Rails.application.middleware.map(&:klass)
    assert_operator stack.index(BadRequestBody), :<, stack.index(Rack::MethodOverride)
  end
end
