# A news item for "Latest" on company and plant pages (#137): headline,
# date, publisher, a one-line neutral summary and the link. A fact like any
# other: sourced through evidence, written through Directory::FactWriter
# (kind :news_item), and public only once a person approves it (Tosin, 21 Oct
# 2026: approve each). Its mentions say which companies and plants it's about.
class NewsItem < ApplicationRecord
  include Verifiable

  has_many :news_mentions, dependent: :delete_all

  normalizes :url, :title, :publisher, with: ->(value) { value.strip.presence }
  # One line, spaces collapsed, before the 80-character check.
  normalizes :headline, with: ->(value) { value.squish.presence }

  validates :url, presence: true, uniqueness: true, format: { with: %r{\Ahttps?://\S+\z} }
  validates :title, :published_on, presence: true
  validates :confidence, numericality: { in: 0..1 }, allow_nil: true
  # A short headline for Latest (PM, 30 Oct), when the title is a long docket string.
  HEADLINE_MAX = 80
  validates :headline, length: { maximum: HEADLINE_MAX }, allow_nil: true

  # What Latest shows: the headline when there is one, else the title.
  def display_title = headline.presence || title

  # Public: approved by a person (never by an agent: Tosin approves each,
  # 21 Oct), and about at least one published company or plant.
  def self.published
    approved = verified.where("news_items.verified_by LIKE 'human:%'")
    approved.where(id: NewsMention.where(subject_type: "Organization", subject_id: Organization.published.select(:id)).select(:news_item_id))
      .or(approved.where(id: NewsMention.where(subject_type: "Facility", subject_id: Facility.published.select(:id)).select(:news_item_id)))
  end

  # A record's "Latest": its public items, newest first.
  def self.latest_for(record) = published.where(id: NewsMention.where(subject: record).select(:news_item_id)).order(published_on: :desc, id: :desc)
end
