# Fills in a URL slug from the name when none is given. For records that opt
# in with `self.suffixes_slug = true` (Facility, where an EIA site and an NRC
# unit can share a name), the slug falls back to "-2", "-3"... when the plain
# one is taken (#134); without the opt-in, a taken slug fails uniqueness, so
# duplicates can't quietly save as "name-2" (#154). A slug given explicitly
# must be free. Slugs are stable: renaming a record doesn't change its slug.
# When a slug is changed on purpose, the old one is kept as a FormerSlug
# (#143), so the old address still finds the record.
module Sluggable
  extend ActiveSupport::Concern

  included do
    class_attribute :suffixes_slug, default: false

    has_many :former_slugs, as: :sluggable, dependent: :delete_all

    before_validation { self.slug = free_slug(name.parameterize) if slug.blank? && name.present? }
    after_save :remember_former_slug, if: :saved_change_to_slug?

    validates :slug, presence: true, uniqueness: true
  end

  class_methods do
    # The record that used to be at slug (renamed, or merged into another), or nil.
    def find_by_former_slug(slug)
      FormerSlug.find_by(sluggable_type: base_class.name, slug: slug.to_s)&.sluggable
    end
  end

  def to_param
    slug
  end

  # Points an old slug (this record's, or one a merged record had) at this record.
  def remember_slug(old)
    return if old.blank? || old == slug

    FormerSlug.where(sluggable_type: self.class.base_class.name, slug: old).delete_all
    former_slugs.create!(slug: old)
  end

  private
    # A live slug always wins over a former one of the same text.
    def remember_former_slug
      FormerSlug.where(sluggable_type: self.class.base_class.name, slug:).delete_all
      remember_slug(slug_before_last_save) if slug_before_last_save.present?
    end

    def free_slug(base)
      return base unless self.class.suffixes_slug

      taken = self.class.where.not(id:).where("slug = ? OR slug LIKE ?", base, "#{base}-%").pluck(:slug).to_set
      return base unless taken.include?(base)

      (2..).lazy.map { |n| "#{base}-#{n}" }.find { |slug| !taken.include?(slug) }
    end
end
