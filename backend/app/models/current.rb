class Current < ActiveSupport::CurrentAttributes
  attribute :session
  # The admin Live list's cache stamp, read once a request (Directory::LiveList.stamp).
  attribute :live_stamp
  delegate :user, to: :session, allow_nil: true
end
