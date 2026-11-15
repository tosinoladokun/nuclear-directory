# Forward to leads (#757; Tosin, 10 Nov): Tosin forwards any email (a
# LinkedIn suggestion, a newsletter, a news alert) to leads@ and its
# companies become leads in the one lead pipeline (#752). The newsletter
# reader's crawl, storage (visible text and cleaned links only) and model,
# with three differences:
# - only mail from LEADS_ALLOWED_SENDERS (comma-separated addresses or "@domain"
#   for exactly that domain; never mail.nuclear-directory.org; in the environment, never
#   in the repo) with DMARC pass is read; anything else is dropped unread;
# - any company the email names, not only US ones (the lead finder checks);
# - one short reply to the allow-listed address that sent it: "Added N leads: A, B. Already listed: C."
# A LinkedIn link is never opened: the lead finder takes its name only.
class DataQuality::Plugins::LeadForwards < DataQuality::Plugins::Newsletters
  INBOX = "leads@mail.nuclear-directory.org".freeze
  SEND_API = "https://api.resend.com/emails".freeze
  PUBLIC_MAIL = %w[gmail.com googlemail.com icloud.com me.com mac.com outlook.com hotmail.com live.com msn.com yahoo.com aol.com
    proton.me protonmail.com].freeze
  class ReplyFailed < StandardError; end
  INSTRUCTIONS = <<~TEXT.freeze
    You read one email someone forwarded to suggest companies for a nuclear industry directory. List the companies it names
    that may work in the nuclear industry (reactors, fuel, enrichment, suppliers, utilities with nuclear plants, isotopes,
    nuclear engineering, nuclear investors). Not government agencies, national labs, universities, associations or people.
    For each: name exactly as written; quote, a sentence or phrase from the email naming it; website, only a link from the
    email that is plainly the company's own site (its home page), else null. Report nothing else.
  TEXT

  def initialize(forwarders: ENV["LEADS_ALLOWED_SENDERS"], sender: nil, **options)
    super(**options)
    entries = forwarders.to_s.split(",").map { |address| address.strip.downcase }.reject(&:blank?)
    # A whole public mail provider is never a sender (Infra): such an entry is ignored, with a warning.
    public = entries.select { |entry| PUBLIC_MAIL.include?(entry.delete_prefix("@")) && entry.start_with?("@") }
    public.each { |entry| Rails.logger.warn("[lead_forwards] ignoring #{entry} in LEADS_ALLOWED_SENDERS: a public mail domain") }
    @forwarders = entries.map { |entry| public.include?(entry) ? nil : entry }
    @sender = sender
  end

  def crawl(run)
    return { "skipped" => "no LEADS_ALLOWED_SENDERS" } if @forwarders.compact.empty?

    super
  end

  def source_facts(_source)
    "This is one email forwarded to our leads@ address to suggest companies: a lead only, never cited for a fact."
  end

  private
    def inbox = INBOX
    def instructions = INSTRUCTIONS
    def lead_key = "forward"
    def lead_label = "Forwarded"

    # Only the allow-listed addresses themselves, never a display name or another sender.
    # Our own sending domain is never read, so a reply can't loop (PM, 11 Nov).
    OWN_DOMAIN = "mail.nuclear-directory.org".freeze

    # An entry is a full address, or "@domain" for every address at exactly
    # that domain (no subdomains). Returns the entry's place in the list.
    def entry_for(from)
      address = Mail::Address.new(from.to_s).address.to_s.downcase
      domain = address.split("@", 2).last.to_s
      return if address.blank? || domain.blank? || domain == OWN_DOMAIN

      @forwarders.index(address) || @forwarders.index("@#{domain}")
    rescue Mail::Field::ParseError
      nil
    end

    def sender?(from) = !entry_for(from).nil?

    # Which allow-listed address sent it, by its place in the list (no address is stored).
    # Which entry let it in: its place in the list, and for a whole-domain entry
    # the mailbox's local part (so the reply goes back to the sender only).
    def sender_attributes(mail)
      index = entry_for(mail["from"]) or return {}
      return { last_modified: "sender:#{index}" } unless @forwarders[index].start_with?("@")

      { last_modified: "sender:#{index}:#{Mail::Address.new(mail['from'].to_s).local.to_s.downcase}" }
    end

    # One reply per email, to the forwarder, sent once (the source remembers it in its etag).
    def after_leads(source, added, listed)
      return if source.etag == "replied"

      # The allow-listed address that sent it (Infra), never another one.
      index, local = source.last_modified.to_s.match(/\Asender:(\d+)(?::([^@\s:]+))?\z/)&.captures
      entry = index && @forwarders[index.to_i] or return
      to = entry.start_with?("@") ? (local.present? ? "#{local}#{entry}" : nil) : entry
      return unless to
      lines = [ "Added #{added.size} #{'lead'.pluralize(added.size)}#{": #{added.join(', ')}" if added.any?}." ]
      lines << "Already listed: #{listed.join(', ')}." if listed.any?
      # One Idempotency-Key per email, so a retry after a lost answer never sends a second reply (Copilot);
      # a failed send raises, so the extraction isn't marked done and the next run tries again.
      sent = (@sender || method(:send_reply)).call(to:, subject: "Re: #{source.title.to_s.split(': ', 2).last}", text: lines.join("\n"),
        key: "lead-forwards-#{source.id}")
      raise ReplyFailed, "Resend didn't take the reply for source #{source.id}" unless sent

      source.update_columns(etag: "replied")
    end

    def send_reply(to:, subject:, text:, key:)
      uri = URI(SEND_API)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |client|
        client.post(uri.path, { from: "Nuclear Directory <#{INBOX}>", to: [ to ], subject:, text: }.to_json,
          { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json", "Idempotency-Key" => key,
            "User-Agent" => DataQuality::Fetcher::USER_AGENT })
      end
      response.is_a?(Net::HTTPSuccess)
    end
end
