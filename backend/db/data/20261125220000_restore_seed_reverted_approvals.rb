# #947 (P0): the data step after #943 (deploy f890324, 20:06 UTC, 25 Nov) ran the seed, which wrote its files'
# null and older values over 16 that Tosin had approved in Today that afternoon (verification events 4254–4269).
# This puts back the value he approved for each, with no new approval: his approval event and its claim stand.
#
# The seed files now hold the approved values (this PR), so the seed in the same deploy may restore them first;
# this step then has nothing to do and says so. Its own write is the record that the restore was this fix.
#
# Pinned on each revert event as Data Quality read it in production on 25 Nov (dq-947-approved-values): its record,
# and each field's approved value (the event's "from") and the seed's value (its "to"). A field is put back only
# while the record still holds the seed's value; one that holds anything else was decided again and is left, and said.
class RestoreSeedRevertedApprovals < DeployData::Migration
  BY = "human:tosin"
  # revert event id => [record type, record id, approval event id, { field => [approved, seed's value] }]
  EVENTS = {
    4254 => [ "Organization", 115, 4216, { "hq_city" => [ "Natick", nil ], "hq_state" => [ "MA", nil ] } ],
    4255 => [ "Organization", 165, 4206, { "hq_city" => [ "Upton", nil ], "hq_state" => [ "NY", nil ] } ],
    4256 => [ "Organization", 116, 4215, { "hq_city" => [ "Stony Brook", nil ], "hq_state" => [ "NY", nil ] } ],
    4257 => [ "Organization", 93, 4214, { "hq_city" => [ "Lynchburg", nil ], "hq_state" => [ "VA", nil ] } ],
    4258 => [ "Organization", 53, 4212, { "hq_city" => [ "Dalton", nil ], "hq_state" => [ "GA", nil ] } ],
    4259 => [ "Organization", 11, 4152, { "hq_city" => [ "Lakewood", "Denver" ] } ],
    4260 => [ "Organization", 55, 4211, { "hq_city" => [ "Atlanta", nil ], "hq_state" => [ "GA", nil ] } ],
    4261 => [ "Organization", 123, 4209, { "hq_city" => [ "Midland", nil ], "hq_state" => [ "TX", nil ] } ],
    4262 => [ "Organization", 56, 4208, { "hq_city" => [ "Tucker", nil ], "hq_state" => [ "GA", nil ] } ],
    4263 => [ "Organization", 57, 4207, { "hq_city" => [ "Glen Allen", nil ], "hq_state" => [ "VA", nil ] } ],
    4264 => [ "Organization", 167, 4205, { "hq_city" => [ "Richland", nil ], "hq_state" => [ "WA", nil ] } ],
    4265 => [ "Organization", 113, 4202, { "hq_city" => [ "Huntsville", nil ], "hq_state" => [ "AL", nil ] } ],
    4266 => [ "Organization", 129, 4201, { "website" => [ "https://standardpower.com", nil ] } ],
    4267 => [ "Organization", 38, 4234, { "hq_city" => [ "Knoxville", "Madison" ], "hq_state" => [ "TN", "WI" ] } ],
    4268 => [ "Organization", 168, 4204, { "hq_city" => [ "Birmingham", nil ], "hq_state" => [ "AL", nil ] } ],
    4269 => [ "Relationship", 36, 4240, { "description" => [
      "Announced agreement (May 2023): Helion to supply Microsoft electricity from its first fusion plant, expected to be online by 2028 and to target 50 MW or greater after a 1-year ramp-up.",
      "Signed fusion PPA (May 2023): Helion to supply Microsoft electricity from its first fusion plant, 50 MW+ targeted from 2028."
    ] } ]
  }.freeze
  KINDS = { "Organization" => :organization, "Relationship" => :relationship }.freeze

  def up
    EVENTS.each do |event_id, (type, id, approval_id, fields)|
      record = type.constantize.find_by(id:)
      next say("#{type} #{id} is gone; nothing to restore for event #{event_id}") unless record
      # Taken off, rejected or sent back since: a restore must never publish it again (Copilot, #948).
      next say("#{label(record)} is #{record.verification_status} now; left as it is") unless record.verification_status == "verified"
      next say("Event #{event_id} isn't the seed's revert of #{type} #{id} as read on 25 Nov; #{type} #{id} left as it is") unless pinned?(event_id, type, id, fields)

      current = fields.keys.to_h { |field| [ field, record.public_send(field) ] }
      approved = fields.transform_values(&:first)
      next say("#{label(record)}: already holds the approved #{fields.keys.join(' and ')}") if current == approved

      restore = fields.select { |field, (_, seed_value)| current[field] == seed_value }.transform_values(&:first)
      decided = fields.keys - restore.keys - approved.select { |field, value| current[field] == value }.keys
      say("#{label(record)}: #{decided.join(' and ')} changed again since the seed run; left as it is") if decided.any?
      next if restore.empty?

      result = Directory::FactWriter.write(KINDS.fetch(type), restore.merge(id:),
        verification: { status: "verified", by: BY,
          reason: "Restores Tosin's approval (event #{approval_id}), undone by the seed run of 25 Nov (#947); #{reason}",
          context: { "restores_event" => event_id, "approval_event" => approval_id } })
      raise "restoring #{type} #{id} failed: #{Array(result.errors).join('; ')}" unless result.ok?

      say "#{label(record)}: restored #{restore.map { |field, value| "#{field} #{value.inspect}" }.join(', ')}"
    end
  end

  private
    # The event is the seed's write as Data Quality read it: same record, and each field went from the approved
    # value to the seed's.
    def pinned?(event_id, type, id, fields)
      event = VerificationEvent.find_by(id: event_id) or return false
      return false unless [ event.subject_type, event.subject_id ] == [ type, id ]

      fields.all? { |field, (approved, seed_value)| event.changed_values[field] == [ approved, seed_value ] }
    end

    def label(record) = record.respond_to?(:slug) ? "#{record.name} (#{record.class.name} #{record.id})" : "#{record.class.name} #{record.id}"
end
