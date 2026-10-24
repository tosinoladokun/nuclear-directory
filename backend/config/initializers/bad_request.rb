# A malformed request body gets a plain 400 instead of a 500 and a Sentry
# error. Scanners send these. Rack's multipart parse errors all include
# Rack::BadRequest, so one rescue covers them. Rack::MethodOverride parses
# a POST's body to look for _method, and it sits above Rails' exception
# handling, so a bad body reaches the server as a 500 without this.
class BadRequestBody
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue Rack::BadRequest
    [ 400, { "content-type" => "text/plain; charset=utf-8" }, [ "Bad request\n" ] ]
  end
end

Rails.application.config.middleware.insert_before Rack::MethodOverride, BadRequestBody
