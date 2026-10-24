# Research (SourceCatalog::RESEARCH_KIND): pages a person or a research
# session cited by hand. Nothing is crawled or extracted here; the plug-in
# exists so a claim on such a page can be matched and verified again after a
# person settles its company with Same as… (#391).
class DataQuality::Plugins::WebPage < DataQuality::Plugin
  def crawl(_run) = {}

  def extract(_source, _run) = []
end
