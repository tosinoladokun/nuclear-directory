# #147: the Host-header allowlist for production.rb. render.yaml sets
# APP_HOSTS per service (the web service, the UI preview); CI's Lighthouse
# audit and a local production run leave it unset, so no restriction
# applies to those. The parsing lives here, not inline in production.rb,
# so production_hosts_test.rb exercises the same code (not duplicated
# literals that could drift).
module AppHosts
  def self.from_env(env)
    env.fetch("APP_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
  end
end
