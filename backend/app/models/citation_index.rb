# Numbers the sources cited on one page, in order of first use, so each
# source chip matches an entry in the page's numbered source list.
#
#   index = CitationIndex.new
#   index.cite(fact.evidence)  # => [[1, source], [2, source]]
#   index.sources              # => [[1, source], [2, source], ...]
class CitationIndex
  def initialize
    @numbers = {}
    @sources = {}
    @checked = {}
  end

  # Evidence for one fact => [[number, source], ...], strongest first,
  # one entry per source.
  # checked: when the fact was last verified; the page's source list shows the latest date for each source
  # (an opened row doesn't, #655).
  def cite(evidence, checked: nil)
    Array(evidence).sort_by { |e| -(e.confidence || 0) }.map(&:source).uniq(&:id).map do |source|
      @sources[source.id] ||= source
      @checked[source.id] = [ @checked[source.id], checked ].compact.max if checked
      [ @numbers[source.id] ||= @numbers.size + 1, source ]
    end
  end

  def sources = @numbers.map { |id, number| [ number, @sources[id] ] }

  # { number => the latest date a fact citing that source was verified }
  def checked = @numbers.to_h { |id, number| [ number, @checked[id]&.to_date ] }.compact
end
