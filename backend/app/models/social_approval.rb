# Data Quality's recorded PASS of one exact text (#897): the SHA-256 it graded, for a company and platform. The approved-drafts endpoint
# refuses a text nobody at Data Quality recorded a hash for, so "graders: DQ" is a fact on file and not a claim by the caller.
class SocialApproval < ApplicationRecord
  validates :platform, inclusion: { in: SocialChannel::PLATFORMS }
  validates :slug, :approved_by, presence: true
  validates :sha256, format: { with: /\A\h{64}\z/ }, uniqueness: { scope: %i[platform slug] }
  before_validation { self.sha256 = sha256.to_s.strip.downcase }
end
