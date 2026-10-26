# Checks render.yaml for mistakes that would deploy without an error but
# break backups or expose the database. Run by CI (blueprint job).
require "yaml"

# age public keys are Bech32 (BIP 173) with the "age" prefix. Checking the
# checksum catches a mistyped key before the daily backup fails on it.
BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def bech32_valid?(string)
  hrp, data = string.downcase.match(/\A(.+)1([#{BECH32}]{6,})\z/)&.captures
  return false if hrp.nil? || string != string.downcase

  values = hrp.bytes.map { |b| b >> 5 } + [ 0 ] + hrp.bytes.map { |b| b & 31 } + data.chars.map { |c| BECH32.index(c) }
  generators = [ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 ]
  checksum = values.reduce(1) do |chk, value|
    top = chk >> 25
    chk = ((chk & 0x1ffffff) << 5) ^ value
    5.times.reduce(chk) { |acc, i| top[i] == 1 ? acc ^ generators[i] : acc }
  end
  checksum == 1
end

# A database may allow single IPv4 hosts (/32) that say whose they are, e.g.
# Tosin's home IP for local Metabase (#111). Anything wider stays blocked.
def allowed_ip_entry?(entry)
  return false unless entry.is_a?(Hash) && entry["description"].to_s.strip != ""

  octets = entry["source"].to_s.match(/\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/32\z/)&.captures&.map(&:to_i)
  !octets.nil? && octets.all? { |octet| octet <= 255 } && octets != [ 0, 0, 0, 0 ]
end

# RENDER_YAML lets the test point this at sample blueprints.
blueprint = YAML.load_file(ENV.fetch("RENDER_YAML", File.expand_path("../../render.yaml", __dir__)))
problems = []

backup = blueprint["services"].find { |service| service["name"] == "nuclear-directory-backup" }
if backup.nil?
  problems << "the nuclear-directory-backup cron job is missing"
else
  recipient = backup["envVars"].find { |var| var["key"] == "BACKUP_AGE_RECIPIENT" }&.dig("value").to_s
  # An age X25519 public key: "age1" plus 58 bech32 characters.
  unless recipient.match?(/\Aage1[#{BECH32}]{58}\z/) && bech32_valid?(recipient)
    problems << "BACKUP_AGE_RECIPIENT is #{recipient.inspect}, not an age public key (age1...)"
  end
end

# The web service's pre-deploy backup (#301) must use the same key: a
# different one would make backups only that key could read.
web = blueprint["services"].find { |service| service["name"] == "nuclear-directory" }
web_recipient = web&.fetch("envVars", [])&.find { |var| var.is_a?(Hash) && var["key"] == "BACKUP_AGE_RECIPIENT" }
if web_recipient && backup && web_recipient["value"] != recipient
  problems << "nuclear-directory's BACKUP_AGE_RECIPIENT must match the backup cron job's"
end

# Tokens and the data deploy's kill switch are set in the dashboard only:
# sync: false, never a value or a reference, wherever they appear.
DASHBOARD_ONLY = %w[BACKUP_GITHUB_TOKEN DEPLOY_REPORT_GITHUB_TOKEN AUTO_DATA_DEPLOY DQ_AGENT_TOKEN_DIGEST].freeze
blueprint["services"].each do |service|
  service.fetch("envVars", []).each do |var|
    next unless var.is_a?(Hash) && DASHBOARD_ONLY.include?(var["key"])
    next if var.keys.sort == %w[key sync] && var["sync"] == false

    problems << "#{service["name"]}'s #{var["key"]} must be sync: false (set in the dashboard), never a value"
  end
end

# The UI preview must never reach production data or carry production secrets.
preview = blueprint["services"].find { |service| service["name"] == "nuclear-directory-preview" }
if preview
  entries = preview.fetch("envVars", [])
  # Only these keys, each a plain value, generated, or (DATABASE_URL) set by
  # hand. No fromDatabase, fromService or fromGroup anywhere: any of them could
  # hand production's connection string or secrets to preview code, under
  # whatever name.
  allowed = %w[DATABASE_URL NOINDEX DISABLE_DATABASE_ENVIRONMENT_CHECK SECRET_KEY_BASE RAILS_MAX_THREADS WEB_CONCURRENCY PREVIEW_ADMIN_PASSWORD APP_HOSTS]
  references = %w[fromDatabase fromService fromGroup]
  entries.each do |var|
    if !var.is_a?(Hash) || var["key"].to_s.empty? || references.any? { |ref| var.key?(ref) }
      problems << "the preview may not take values from other services, databases or environment groups " \
        "(fromDatabase, fromService, fromGroup): #{var.inspect}"
    elsif !allowed.include?(var["key"])
      problems << "the preview must not set #{var["key"]} (allowed: #{allowed.join(", ")})"
    end
  end
  vars = entries.select { |var| var.is_a?(Hash) && var["key"] }.to_h { |var| [ var["key"], var ] }
  # Every entry with the key, so a duplicate can't hide a checked-in value.
  admin_passwords = entries.select { |var| var.is_a?(Hash) && var["key"] == "PREVIEW_ADMIN_PASSWORD" }
  unless admin_passwords.size == 1 && admin_passwords.all? { |var| var["sync"] == false && var.keys.sort == %w[key sync] }
    problems << "the preview's PREVIEW_ADMIN_PASSWORD must be listed once, as sync: false (set by hand), never a value"
  end
  database_url = vars["DATABASE_URL"]
  unless database_url && database_url["sync"] == false && !database_url.key?("value")
    problems << "the preview's DATABASE_URL must be sync: false (set by hand to the preview database), never fromDatabase or a value"
  end
  problems << "the preview must set NOINDEX to \"1\"" unless vars.dig("NOINDEX", "value").to_s == "1"
  problems << "the preview must not have custom domains" if preview["domains"]
end

# The web service's Host-header allowlist (#147). A deleted line would
# silently turn the protection off, so insist it names nuclear-directory.org
# as a plain value.
web = blueprint["services"].find { |service| service["name"] == "nuclear-directory" }
if web
  app_hosts = web.fetch("envVars", []).find { |var| var.is_a?(Hash) && var["key"] == "APP_HOSTS" }
  value = app_hosts&.dig("value").to_s
  hosts = value.split(",").map(&:strip).reject(&:empty?)
  unless app_hosts && app_hosts.keys.sort == %w[key value] && hosts.include?("nuclear-directory.org")
    problems << "nuclear-directory's APP_HOSTS must be a plain value including nuclear-directory.org (#147)"
  end
end

# The preview's admin login must never exist anywhere else.
blueprint["services"].each do |service|
  next if service["name"] == "nuclear-directory-preview"

  if service.fetch("envVars", []).any? { |var| var.is_a?(Hash) && var["key"] == "PREVIEW_ADMIN_PASSWORD" }
    problems << "#{service["name"]} must not set PREVIEW_ADMIN_PASSWORD (preview only)"
  end
end

blueprint["databases"].each do |database|
  allow_list = database["ipAllowList"]
  # At most one host: Tosin's Mac for local Metabase (#111), nothing else.
  unless allow_list.is_a?(Array) && allow_list.size <= 1 && allow_list.all? { |entry| allowed_ip_entry?(entry) }
    problems << "database #{database["name"]} may only allow one IPv4 host (x.x.x.x/32) with a description; " \
      "use ipAllowList: [] for no access from the internet"
  end
end

if problems.empty?
  puts "render.yaml OK"
else
  problems.each { |problem| puts "::error file=render.yaml::#{problem}" }
  exit 1
end
