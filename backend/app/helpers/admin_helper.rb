# Wording for the admin screens (#86), in visitors' words where a fact is
# described (VOICE.md) and plainly elsewhere.
module AdminHelper
  KIND_LABELS = {
    "organization" => "Companies", "facility" => "Plants and sites", "organization_role" => "Company roles",
    "organization_technology" => "Company technologies", "relationship" => "Deals between companies",
    "facility_relationship" => "Plant owners and operators"
  }.freeze
  TYPE_LABELS = {
    "Organization" => "Company", "Facility" => "Plant or site", "OrganizationRole" => "Company role",
    "OrganizationTechnology" => "Company technology", "Relationship" => "Deal between companies",
    "FacilityRelationship" => "Plant owner or operator"
  }.freeze
  STATUS_WORDS = { "verified" => "Verified", "pending" => "Pending", "rejected" => "Rejected", "unpublished" => "Unpublished" }.freeze

  CRAWL_STATUS_LABELS = { "ok" => "OK", "blocked" => "Blocked", "needs_human" => "Needs a human check", "pending" => "Not fetched yet" }.freeze

  # Sources by kind, in the names the admin uses (canvas A).
  SOURCE_KIND_LABELS = {
    "nrc_reactor_list" => "NRC", "nrc_power_status" => "NRC", "eia_generators" => "EIA", "eia_860m_index" => "EIA",
    "usaspending_doe_awards" => "USAspending", "usaspending_api" => "USAspending", "nrc_decommissioning" => "NRC", "doe_isotope_sites" => "DOE", "nrc_uranium_recovery" => "NRC",
    "web_page" => "Research"
  }.freeze

  def source_kind_label(kind) = SOURCE_KIND_LABELS.fetch(kind.to_s) { kind.to_s.humanize }

  # The left nav (#201): each stage with its count, then Correction requests
  # after a gap. A stage whose screen isn't built yet is listed, greyed, as
  # "Soon" (soon: true), with no link.
  def admin_nav_items
    counts = admin_nav_counts
    [
      { label: "Overview", path: admin_root_path, current: controller_name == "overview" },
      { label: "Sources", path: admin_sources_path, count: counts[:sources], current: controller_name == "sources" },
      { label: "Checks", path: admin_checks_path, count: counts[:checks], current: %w[checks candidates pending_facts].include?(controller_name) },
      { label: "Live", path: admin_live_path, count: counts[:live], current: %w[live records].include?(controller_name) },
      { label: "Removed", soon: true },
      { label: "Where it appears", path: admin_outputs_path, count: counts[:outputs], current: controller_name == "outputs" },
      { label: "Correction requests", path: admin_corrections_path, count: counts[:corrections], title: "From visitors", gap: true,
        current: controller_name == "corrections" }
    ]
  end

  # A source's status in Design's words (#201 part 2b): OK with an ink dot;
  # not fetched yet, muted ("Not checked by the crawler" for hand research);
  # Blocked and Needs a person in critical.
  def source_status(status, research:)
    case status.to_s
    when "ok" then tag.span("OK", class: "nd-dot")
    when "blocked" then tag.span("Blocked", class: "text-critical")
    when "needs_human" then tag.span("Needs a person", class: "text-critical")
    else tag.span(research ? "Not checked by the crawler" : "Not read yet", class: "text-ink-muted")
    end
  end

  ISSUES_URL = "https://github.com/tosinoladokun/nuclear-directory/issues".freeze

  # "8 of 9 categories have no live source", "1 of 9 categories has …".
  def uncovered_line(uncovered, total) = "#{uncovered} of #{total} #{'category'.pluralize(total)} #{uncovered == 1 ? 'has' : 'have'} no live source"

  # A source's status on Sources by category (#166): Live with an ink dot;
  # Built, Planned or Missing with its issue (linked, opening GitHub); Hand
  # research with its documents.
  def coverage_status(source)
    issue = link_to("##{source.issue}", "#{ISSUES_URL}/#{source.issue}", class: "nd-link", target: "_blank", rel: "noopener") if source.issue
    case source.status
    when "live" then tag.span("Live", class: "nd-dot")
    when "built" then tag.span(safe_join([ "Built", (safe_join([ " · ", issue ]) if issue), ", not running yet" ]), class: "text-ink-muted")
    when "planned" then tag.span(safe_join([ "Planned · ", issue ]), class: "text-ink-muted")
    when "hand"
      # A count only where documents are mapped to it; otherwise it isn't known, not zero.
      documents = (" · #{pluralize(source.documents, 'document')}" if source.documents)
      # Its issue is the crawler that will take it over (crawler: true), or the research task.
      tag.span(safe_join([ "Hand research#{documents}", (safe_join([ source.crawler ? " · crawler " : " · ", issue ]) if issue) ]), class: "text-ink-muted")
    else tag.span(issue ? safe_join([ "Planned · ", issue ]) : "Missing · no issue yet", class: issue ? "text-ink-muted" : "text-critical")
    end
  end

  # Text with each match of the query marked (<mark>), escaped.
  def mark_matches(text, query)
    return text.to_s if query.blank?

    safe_join(text.to_s.split(/(#{Regexp.escape(query)})/i).map { |part| part.casecmp?(query) ? tag.mark(part) : part })
  end

  # A Live URL for the list as it is, with a tab, a chip toggled (a Status
  # chip replaces the status; others add or drop), or everything cleared.
  def live_path_for(list, tab: list.tab, toggle: nil, clear: false, without_source: false)
    chosen = clear ? { "status" => [ Directory::LiveList::DEFAULT_STATUS ] } : list.chosen.transform_values(&:dup)
    if (tag = toggle && Directory::Checks.find(toggle))
      keys = chosen[tag.group] ||= []
      if Directory::Checks::SINGLE.include?(tag.group) then chosen[tag.group] = [ tag.key ]
      elsif keys.include?(tag.key) then keys.delete(tag.key)
      else keys << tag.key
      end
    end
    status = Array(chosen["status"]).first
    admin_live_path({ tab: (tab unless tab == "all"), q: (list.query unless clear), within: (list.within unless clear || without_source), status: (status unless status == Directory::LiveList::DEFAULT_STATUS) }
      .merge(Directory::Checks::GROUPS.keys.excluding("status").to_h { |group| [ group.to_sym, Array(chosen[group]).join(",").presence ] }).compact)
  end

  # Where a Live row opens: a company's or plant's Record page, else the
  # fact page; either with a way back to this list.
  def live_row_path(row, back)
    if row.type == "Organization" || (row.type == "Facility" && row.kind == "Plant")
      admin_record_path(type: row.type, id: row.id, back:)
    else
      admin_fact_path(type: row.type, id: row.id, from: "live", back:)
    end
  end

  # The flash after a decision made on an item page, on the next one:
  # "Approved. 4 of 6." (the count as the list is now).
  def admin_notice
    list = controller.instance_variable_get(:@list)
    flash[:decided] && list ? "#{notice} #{list[:index]} of #{list[:total]}." : notice
  end

  # Counts for the nav and the Overview tiles, once per request.
  def admin_nav_counts
    @admin_nav_counts ||= {
      sources: SourceCatalog.total,
      checks: DataQuality::Review.counts.values.sum + DataQuality::Review.pending_count,
      live: Organization.published.count + Facility.published.where(parent_id: nil).count,
      corrections: CorrectionReport.where(status: %w[open reviewed]).count,
      outputs: PublicPages.new.count
    }
  end

  # A source's crawl status in one wording, wherever it's shown.
  def crawl_status_label(status) = CRAWL_STATUS_LABELS.fetch(status.to_s, status.to_s.humanize)

  # Who decided, as the screen shows it: "tosin" for "human:tosin", "the
  # verifier (model)" for an agent. The data keeps the prefix.
  def who(by)
    by = by.to_s
    return by.delete_prefix("human:") if by.start_with?("human:")
    return "the verifier (#{by.delete_prefix('agent:verifier/')})" if by.start_with?("agent:verifier/")

    by
  end

  # Reply to a visitor's correction: their address, a subject, and the page.
  def correction_reply_mailto(report)
    # Encoded, so a crafted address ("a@b.c?bcc=…") can't add recipients or headers.
    "mailto:#{ERB::Util.url_encode(report.contact).gsub('%40', '@')}?" + { subject: "Your correction on Nuclear Directory",
      body: "About #{request.base_url}#{report.page_path}\n\n" }.to_query.gsub("+", "%20")
  end

  # Ids of linked records; their names are shown instead.
  HIDDEN_FIELDS = %i[organization_id facility_id from_organization_id to_organization_id parent_id].freeze

  def kind_label(kind) = KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)

  # The public page of a published company or plant, or nil.
  def public_page_path(fact)
    slug = fact.values["slug"].presence
    return unless fact.published && slug

    case fact.type
    when "Organization" then company_path(slug:)
    when "Facility" then plant_path(slug:)
    end
  end

  # A pending fact as one line: its name, or the link in words
  # ("Southern Company owns Vogtle 3").
  def fact_heading(fact)
    values = fact.attributes.symbolize_keys
    verb = ->(type) { DataQuality::Claim::RELATIONSHIP_VERBS.fetch(type.to_s, type.to_s.humanize(capitalize: false)) }
    case fact.kind
    when "organization", "facility" then values[:name]
    when "organization_role" then "#{values[:organization_name]}: #{role_label(values[:role]).downcase_first}"
    when "organization_technology" then "#{values[:organization_name]}: #{values[:technology].to_s.humanize(capitalize: false)}"
    when "relationship" then "#{values[:from_organization_name]} #{verb.(values[:relationship_type])} #{values[:to_organization_name]}"
    when "facility_relationship" then "#{values[:organization_name]} #{verb.(values[:relationship_type])} #{values[:facility_name]}"
    else "#{type_label(fact.type)} #{fact.id}"
    end
  end
  def type_label(type) = TYPE_LABELS.fetch(type.to_s, type.to_s.titleize)

  # Checks' filter chips, in order (#201).
  CHECK_CHIPS = { "all" => "All", "changed" => "Changed", "links" => "Links", "facts" => "Facts", "duplicates" => "Duplicates" }.freeze
  CHECK_WORDS = { "changed" => "Changed", "links" => "New link", "duplicates" => "Duplicate" }.freeze

  # A waiting claim's label: what it is, then where it's from ("Changed · EIA").
  def check_kicker(item)
    what = CHECK_WORDS[item.category] || (unit_update?(item) ? "Update" : "New #{type_label(item.kind.camelize).downcase_first}")
    from = SOURCE_KIND_LABELS[item.source.source_kind] || source_host(item.source.url)
    "#{what} · #{from}"
  end

  # What the claim is about, in a few words: "Vogtle 1 · Capacity" for a
  # change, "Amazon buys from Talen Energy" for a link, else its name.
  def check_subject(item)
    payload = item.payload
    name = ->(value) { value.is_a?(Hash) ? value.values_at("name", "nrc_docket", "domain").compact.first : value }
    verb = DataQuality::Claim::RELATIONSHIP_VERBS.fetch(payload["relationship_type"].to_s, payload["relationship_type"].to_s.humanize(capitalize: false))
    if item.category == "changed" && item.record && item.differences.any?
      "#{item.record.name} · #{field_label(item.differences.keys.first)}"
    else
      case item.kind
      when "relationship" then "#{name.(payload['from_organization'])} #{verb} #{name.(payload['to_organization'])}"
      when "facility_relationship" then "#{name.(payload['organization'])} #{verb} #{name.(payload['facility'])}"
      when "organization", "facility"
        if unit_update?(item)
          identify = payload["identify"]
          item.record&.name || [ identify["name"], ("unit #{identify['unit']}" if identify["unit"].present?) ].compact.join(" ")
        else
          payload["name"].presence || item.claim
        end
      else item.claim.delete_suffix(".")
      end
    end
  end

  # The value to compare at a glance: old → new for a change, the record a
  # duplicate may be. nil when there's nothing to compare.
  # Any claim that would replace a human-verified value shows it, whatever
  # its group: its notes may predate the value being decided.
  def check_value(item)
    if (difference = item.differences.first)
      _, (stored, incoming) = difference
      return "#{stored.presence || "Not set"} → #{incoming.presence || "Not set"}"
    end

    case item.category
    when "duplicates"
      similar = item.notes.to_s[/but similar: (.+?)\. Same record/, 1] || item.notes.to_s[/the same brand as (.+?)(?:\.|,| \(| Which)/, 1]
      "→ #{similar.split('; ').first}" if similar
    else
      capacity = item.payload["capacity_mw"].presence
      "#{number_with_precision(capacity, precision: 2, strip_insignificant_zeros: true, delimiter: ",")} MW" if capacity && unit_update?(item)
    end
  end

  # An enrichment claim (EIA): values for a unit already in the directory.
  def unit_update?(item) = item.kind == "facility" && item.payload["identify"].is_a?(Hash)

  # Status in words and shape (DESIGN.md): verified solid, pending dashed,
  # rejected struck through in critical, unpublished dashed with its word.
  def status_badge(status)
    word = STATUS_WORDS.fetch(status.to_s, status.to_s.humanize)
    case status.to_s
    when "verified" then tag.span(safe_join([ icon("check", weight: :bold, size: 12), word ]), class: "nd-badge nd-badge--verified")
    when "rejected" then tag.span(safe_join([ icon("x", weight: :bold, size: 12), word ]), class: "nd-badge nd-badge--rejected")
    when "pending" then tag.span(safe_join([ icon("clock", size: 12), word ]), class: "nd-badge nd-badge--pending")
    else tag.span(word, class: "nd-badge nd-badge--pending")
    end
  end

  def field_label(name) = DataQuality::Claim::LABELS.fetch(name.to_s) { name.to_s.humanize }

  # A value for its field: a role in visitors' words ("Reactor designer").
  def field_display(name, value) = name.to_s == "role" && value.present? ? role_label(value) : field_value(value)

  # What a decision changed: "state DE to NJ; aliases …".
  def changes_text(changed_values)
    changed_values.to_h.map do |name, (before, after)|
      "#{field_label(name).downcase_first} #{before.presence || 'blank'} to #{after.presence || 'blank'}"
    end.join("; ")
  end

  def field_value(value)
    case value
    when nil, "" then tag.span("Not set", class: "text-ink-muted")
    when Array then value.empty? ? tag.span("None", class: "text-ink-muted") : value.join(", ")
    when Hash then value.values_at("name", "domain", "nrc_docket").compact.join(", ")
    when Date, Time then tag.span(data_date(value), class: "nd-num")
    when Numeric then tag.span(value.to_s, class: "nd-num")
    # Stored keys such as "power_reactor" or "active" read as words.
    when /\A[a-z]+(_[a-z]+)*\z/ then value.humanize
    else value.to_s
    end
  end

  # "nrc.gov" from a source URL; the URL is shown as text when it isn't http(s).
  def source_host(url)
    URI.parse(url.to_s).host.to_s.delete_prefix("www.").presence || url.to_s
  rescue URI::InvalidURIError
    url.to_s
  end

  def safe_url(url)
    uri = URI.parse(url.to_s.strip)
    url.to_s.strip if %w[http https].include?(uri.scheme&.downcase) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  def percent(confidence) = confidence && "#{(confidence.to_d * 100).floor}%"

  # Model spend: cents, but a few calls' worth reads "under $0.01", not $0.00.
  def money(amount)
    amount = amount.to_d
    amount.positive? && amount < 0.01.to_d ? "under $0.01" : format("$%.2f", amount)
  end

  ACRONYMS = { "ai" => "AI", "nrc" => "NRC", "eia" => "EIA", "llm" => "LLM", "url" => "URL" }.freeze

  # A stats key in words, acronyms kept: "ai_check" => "AI check".
  def stat_label(key)
    key.to_s.humanize(capitalize: false).split.map { |word| ACRONYMS.fetch(word, word) }.join(" ").upcase_first
  end

  # A run's stats in words: "Sources 1; AI check: agreed 95, missed 0".
  def run_detail(stats)
    stats.map do |key, value|
      value = value.map { |k, v| "#{stat_label(k).downcase_first} #{v}" }.join(", ") if value.is_a?(Hash)
      "#{stat_label(key)}#{':' if stats[key].is_a?(Hash)} #{value}"
    end.join("; ").truncate(200)
  end

  # "42.9 s", "72 min", "1 h 12 min".
  def run_duration(seconds)
    return "running" if seconds.nil?
    return "#{seconds} s" if seconds <= 90

    minutes = (seconds / 60.0).round
    minutes < 90 ? "#{minutes} min" : "#{minutes / 60} h #{minutes % 60} min"
  end

  # What happened, in a history row: "Pending to verified".
  def change_text(event)
    [ event.from_status, event.to_status ].compact.map { |status| STATUS_WORDS.fetch(status, status.humanize) }.join(" to ")
  end

  # A merge's "Moved: 3 aliases, 1 evidence, 2 candidates" in the screen's
  # words (Design, #305): "3 other names, 1 source quote, 2 claims". nil
  # when nothing moves.
  MERGE_WORDS = { "alias" => %w[other\ name other\ names], "domain" => %w[domain domains], "role" => %w[role roles],
    "technology" => %w[technology technologies], "facility relationship" => %w[plant\ link plant\ links],
    "relationship" => %w[company\ link company\ links], "evidence" => %w[source\ quote source\ quotes],
    "candidate" => %w[claim claims], "claim" => %w[claim claims], "unit" => %w[unit units],
    "organization role" => %w[role roles], "organization technology" => %w[technology technologies] }.freeze

  SITE_FIELD_WORDS = { "eia_plant_id" => "EIA plant ID", "facility_type" => "type", "technology_id" => "technology",
    "reactor_type" => "reactor type", "capacity_mw" => "capacity", "latitude" => "location", "longitude" => "location" }.freeze

  # A plant merge also names the site fields it fills where the kept plant
  # has none ("eia_plant_id, status"), by the kept plant's name (Design,
  # #325): "fills in Plant Vogtle's EIA plant ID and status".
  def merge_moved_words(moved, into_name: nil)
    return if moved.blank? || moved == "nothing"

    counted, fields = moved.to_s.split(", ").partition { |part| part.match?(/\A\d+ /) }
    parts = counted.filter_map do |part|
      count, what = part.split(" ", 2)
      next if count.to_i.zero?

      key = what.to_s.singularize
      one, many = MERGE_WORDS.fetch(key) { [ key, key.pluralize ] }
      "#{count} #{count.to_i == 1 ? one : many}"
    end
    labels = fields.map { |name| SITE_FIELD_WORDS.fetch(name.strip) { field_label(name.strip).downcase_first } }.uniq
    parts << "fills in #{into_name ? "#{into_name}'s" : 'its'} #{labels.to_sentence(last_word_connector: " and ")}" if labels.any?
    parts.join(", ").presence
  end
end
