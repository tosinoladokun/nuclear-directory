# The home page (#41): one job, search. The wordmark, the search field with
# instant results, a few suggested searches and a card for each bucket with
# companies, plus Plants and sites, naming three of each (#362).
class HomeController < ApplicationController
  # Tests set a seeded Random so the pills they see are always the same.
  class_attribute :suggestion_random, default: nil

  def show
    @cards = HomeCategories.cards
    @suggestions = HomeSuggestions.pick(random: suggestion_random || Random.new)
  end
end
