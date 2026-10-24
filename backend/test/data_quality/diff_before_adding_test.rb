require "test_helper"
require_relative "support/dummy_plugin"

# Tosin, 24 Oct: every source compares what it read with what we hold and
# only proposes changes. A new issue of a source (next month's file) that
# says the same about a pending record doesn't add a second claim to the
# queue. (Rounding counts as the same only where nothing is written:
# FactWriter#confirm, #542. A write still treats it as a change, so a person's
# more precise value is never replaced by a source's rounder one.)
class DataQuality::DiffBeforeAddingTest < ActiveSupport::TestCase
  setup do
    @unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", capacity_mw: "1227.40", latitude: 39.467528,
      verification_status: "pending")
    @august, @september = %w[august september].map do |month|
      Source.create!(url: "https://example.com/#{month}.csv", source_kind: "dummy", crawl_status: "ok", content_text: "Hope Creek 1,NJ,1300")
    end
  end

  # A source whose files are editions (the newer names the older), like EIA's.
  class Editions < DummyPlugin
    def earlier_editions(source) = source.url.include?("september") ? Source.where("url LIKE ?", "%august%").ids : []
  end

  def claim(source) = Candidate.create!(source:, kind: "facility", status: "new", quote: "Hope Creek 1,NJ,1300",
    payload: { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "capacity_mw" => "1300" })

  test "a pending record's claim from a newer issue replaces the same claim from an earlier one" do
    older = claim(@august)
    DataQuality::Stages::Match.call(plugin: Editions.new)
    assert_equal [ "matched", @unit.id ], older.reload.values_at(:status, :subject_id)

    newer = claim(@september)
    DataQuality::Stages::Match.call(plugin: Editions.new)
    assert_equal "matched", newer.reload.status
    assert_equal "confirmed", older.reload.status
    assert_match "a newer issue of the source says the same", older.notes
  end


  test "the same claim from another page of a kind that has no editions isn't replaced" do
    older = claim(@august)
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    claim(@september)
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_equal "matched", older.reload.status
  end

  test "EIA's monthly and yearly files name their earlier editions, oldest first" do
    month = ->(name) { Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/#{name}_generator2026.xlsx", source_kind: "eia_generators") }
    july, august, september = month.("july"), month.("august"), month.("september")
    assert_equal [ july.id, august.id ], DataQuality::Plugins::EiaGenerators.new.earlier_editions(september)
    assert_empty DataQuality::Plugins::EiaGenerators.new.earlier_editions(july)

    year = ->(number) { Source.create!(url: "https://www.eia.gov/electricity/data/eia860/xls/eia860#{number}.zip", source_kind: "eia_plants") }
    y2023, y2024 = year.(2023), year.(2024)
    assert_equal [ y2023.id ], DataQuality::Plugins::EiaPlants.new.earlier_editions(y2024)
  end
end
