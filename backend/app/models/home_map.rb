# Where a latitude and longitude falls on homepage B's US map (#909): d3-geo's geoAlbers (a conic equal-area projection,
# standard parallels 29.5° and 45.5°, centred on the contiguous states), fitted to the 600 by 370 box the outline in
# home/charts/_us_outline was drawn into. The scale and translate are the ones d3 fitted, so a plant's dot lands where
# the outline puts its state.
#
#   HomeMap.point(-87.65, 41.85) # => [391.6, 134.5] (Chicago)
module HomeMap
  WIDTH = 600
  HEIGHT = 370

  RAD = Math::PI / 180
  PARALLELS = [ 29.5, 45.5 ].freeze
  ROTATE = 96.0
  CENTER = [ -0.6, 38.7 ].freeze
  SCALE = 793.3062915140192
  TRANSLATE = [ 299.8352995556035, 182.20678911377985 ].freeze

  S0, S1 = PARALLELS.map { |lat| Math.sin(lat * RAD) }
  N = (S0 + S1) / 2
  C = 1 + S0 * (2 * N - S0)
  R0 = Math.sqrt(C) / N

  # [x, y] in the box, to one decimal place.
  def self.point(longitude, latitude)
    x, y = raw(longitude.to_f + ROTATE, latitude.to_f)
    [ (TRANSLATE[0] + SCALE * (x - ORIGIN[0])).round(1), (TRANSLATE[1] - SCALE * (y - ORIGIN[1])).round(1) ]
  end

  def self.raw(lambda, phi)
    r = Math.sqrt(C - 2 * N * Math.sin(phi * RAD)) / N
    [ r * Math.sin(lambda * RAD * N), R0 - r * Math.cos(lambda * RAD * N) ]
  end
  private_class_method :raw

  ORIGIN = raw(*CENTER).freeze
end
