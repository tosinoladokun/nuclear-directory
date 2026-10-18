# #220: Sign-in and relay rate limits live in a process-wide
# MemoryStore (SessionsController::RATE_LIMIT_STORE,
# RelayController::RATE_LIMIT_STORE), so a sign-in attempt that another
# test ran would otherwise count against the next test's quota. Clearing
# both stores (and Rails.cache, in case anything else is wired through it)
# before every integration test keeps the sign-in path fresh regardless of
# order, which previously made relay_test.rb's "internal-after-sign-out"
# test fail with [nil, nil, nil] when another test went first.
module RateLimitIsolation
  extend ActiveSupport::Concern

  included do
    setup do
      SessionsController::RATE_LIMIT_STORE.clear
      RelayController::RATE_LIMIT_STORE.clear
      Rails.cache.clear
    end
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include RateLimitIsolation
end
