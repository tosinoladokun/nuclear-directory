# An admin on/off switch (#998). A key with no row is off, so a new switch
# ships off until a person turns it on.
#
#   Switch.on?("dq_pass")                         # => false
#   Switch.set!("dq_pass", true, by: "human:tosin")
class Switch < ApplicationRecord
  KEYS = %w[dq_pass].freeze

  validates :key, inclusion: { in: KEYS }, uniqueness: true

  def self.on?(key) = where(key: key.to_s, on: true).exists?

  def self.set!(key, on, by:)
    switch = find_or_initialize_by(key: key.to_s)
    switch.update!(on:, changed_by: by)
    switch
  end
end
