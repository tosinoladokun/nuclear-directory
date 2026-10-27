# A link whose deal terms are all a framework or another non-binding form
# (#487): listed with its stage, never counted as a deal or in a ranking
# (DATA.md: frameworks are listed separately, never counted).
#
#   link.stage          # => "framework", "non_binding" or nil (signed, or no terms)
#   Relationship.staged # the links that are only that
module DealStage
  extend ActiveSupport::Concern

  NON_BINDING = %w[framework mou loi option preorder].freeze
  LABELS = { "framework" => "Framework", "non_binding" => "Non-binding" }.freeze

  included do
    has_many :deal_terms, as: :link, inverse_of: :link
  end

  class_methods do
    # Links whose verified terms are all non-binding.
    def staged
      list = NON_BINDING.map { |agreement| connection.quote(agreement) }.join(", ")
      where(id: DealTerm.verified.where(link_type: name).group(:link_id)
        .having("bool_and(agreement IS NOT NULL AND agreement IN (#{list}))").select(:link_id))
    end

    def signed_or_unstaged = where.not(id: staged.select(:id))
  end

  def stage
    agreements = deal_terms.select { |term| term.verification_status == "verified" }.map(&:agreement)
    return if agreements.empty? || !agreements.all? { |agreement| NON_BINDING.include?(agreement) }

    agreements.include?("framework") ? "framework" : "non_binding"
  end

  def stage_label = LABELS[stage]
end
