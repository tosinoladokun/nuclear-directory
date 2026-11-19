# One IndexNow batch (#811): how many URLs, and whether it was accepted (after its one retry).
class IndexNowSubmission < ApplicationRecord
  # The last two refused in a row: the key or the key file is wrong (as 13 to 19 Nov).
  def self.refused_twice? = order(id: :desc).limit(2).pluck(:accepted).then { |last| last.size == 2 && last.none? }
end
