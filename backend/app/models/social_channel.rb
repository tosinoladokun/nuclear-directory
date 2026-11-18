# A platform the social agent (#769) posts to, with its switch: off, drafts (written and checked, never sent)
# or live. Off until a person turns it on in the admin.
class SocialChannel < ApplicationRecord
  PLATFORMS = %w[x linkedin].freeze
  MODES = %w[off drafts live].freeze

  validates :platform, inclusion: { in: PLATFORMS }, uniqueness: true
  validates :mode, inclusion: { in: MODES }

  def self.for(platform) = find_or_create_by!(platform:)
  def off? = mode == "off"
  def live? = mode == "live"
end
