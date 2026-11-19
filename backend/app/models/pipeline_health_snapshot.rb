# One day of the pipeline's health (#811): its counts and the problems found.
class PipelineHealthSnapshot < ApplicationRecord
  validates :on, presence: true, uniqueness: true
end
