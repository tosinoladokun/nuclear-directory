# IndexNow's key file (#742): /<key>.txt holds the key, so the engines can
# check a ping came from this site. Any other .txt name is "Page not found".
class IndexNowController < ApplicationController
  def key
    request.session_options[:skip] = true
    key = IndexNow.key
    raise ActionController::RoutingError, "not found" unless key && params[:key] == key

    expires_in 1.day, public: true
    render plain: key
  end
end
