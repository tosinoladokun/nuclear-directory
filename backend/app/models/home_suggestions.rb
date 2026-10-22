# The searches suggested under the home page's search box. Change the pool
# here; nothing else needs to. Each page load shows SHOWN of them, picked at
# random on the server (no layout shift), favouring the heavier ones, and
# listed in pool order. A narrow screen shows only the ones that fit. Searches from these links are tracked with source
# "suggestion", so they don't look like typed demand and their clicks can be
# compared. Every query must find 3 or more results (test/seeds_test.rb).
#
#   HomeSuggestions.pick                      # => 5 Suggestions
#   HomeSuggestions.pick(random: Random.new(1)) # the same 5 every time (tests)
module HomeSuggestions
  SHOWN = 5

  # weight: how often it's picked, relative to the others.
  Suggestion = Data.define(:label, :query, :weight) do
    def initialize(label:, query:, weight: 1) = super
  end

  # Founder's research, approved by Tosin on 18 Oct: the top searches weigh
  # most. No "Data center" until search improves. NuScale waits until it finds
  # 3 results (2 in the seed on 18 Oct).
  POOL = [
    Suggestion.new(label: "Oklo", query: "Oklo", weight: 4),
    Suggestion.new(label: "SMR", query: "SMR", weight: 4),
    Suggestion.new(label: "Uranium", query: "Uranium", weight: 4),
    Suggestion.new(label: "Fusion", query: "Fusion", weight: 4),
    Suggestion.new(label: "Constellation", query: "Constellation", weight: 4),
    Suggestion.new(label: "HALEU", query: "HALEU"),
    Suggestion.new(label: "Plant Vogtle", query: "Vogtle"),
    Suggestion.new(label: "TerraPower", query: "TerraPower")
  ].freeze

  # A weighted draw without replacement (each gets rand ** (1 / weight); the
  # highest keys win), shown in pool order so the row reads the same way.
  def self.pick(count = SHOWN, random: Random.new)
    POOL.max_by(count) { |suggestion| random.rand**(1.0 / suggestion.weight) }.sort_by { |suggestion| POOL.index(suggestion) }
  end
end
