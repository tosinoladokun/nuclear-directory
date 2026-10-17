# Asks the extractor model which companies hold the NRC license for the
# reactor on one of NRC's site pages, each with the sentence that says so
# copied exactly. NRC's site pages say it in prose ("ADP-CR3 became the
# NRC-licensed operator responsible for decommissioning"), not in a field,
# so a model reads them; the plug-in then checks every quote against the page.
class DataQuality::Plugins::NrcDecommissioning::Licensees
  # Bump when the prompt or schema changes; stored on the crawl run.
  PROMPT_VERSION = "nrc-decommissioning-licensees-v1"

  SCHEMA = {
    "type" => "object",
    "properties" => {
      "licensees" => {
        "type" => "array",
        "items" => {
          "type" => "object",
          "properties" => {
            "name" => { "type" => "string", "description" => "The company's name, exactly as the page writes it" },
            "link" => { "type" => "string", "enum" => %w[operates owns],
              "description" => "operates: holds the license as the operator responsible for the site; owns: the NRC-licensed owner" },
            "quote" => { "type" => "string", "description" => "The sentence that says so, copied exactly; it must contain the name" },
            "decommissions" => { "type" => "boolean",
              "description" => "true only if the page says this company took over the license to decommission the site, or is a decommissioning company" },
            "decommissioning_quote" => { "type" => "string",
              "description" => "When decommissions is true, the sentence that says so, copied exactly; otherwise empty" }
          },
          "required" => %w[name link quote decommissions decommissioning_quote],
          "additionalProperties" => false
        }
      }
    },
    "required" => [ "licensees" ],
    "additionalProperties" => false
  }.freeze

  INSTRUCTIONS = <<~TEXT.freeze
    You read one page published by the US Nuclear Regulatory Commission (NRC) about a
    nuclear power reactor site, most of them undergoing decommissioning.

    List the companies the page says hold the reactor's NRC license now: the licensee,
    the NRC-licensed operator, or the NRC-licensed owner. Leave out former licensees
    (a company that transferred the license away), contractors, agencies, and people.
    If the page doesn't say who holds the license, return an empty list.

    Copy every name and quote exactly as written, character for character. Never guess,
    correct, expand or shorten a name. Each quote is one sentence from the page that
    states the company's role, and contains the name exactly as you give it.

    Set decommissions to true only when the page says the company took over the license
    in order to decommission the site, or describes it as a decommissioning company.
    A utility decommissioning its own reactor is false.
  TEXT

  def initialize(llm: nil)
    @llm = llm
  end

  # text: the page's main text (NrcDecommissioning.page_text). Returns the
  # model's licensees, string keys.
  def call(text, run:)
    run&.update!(prompt_version: PROMPT_VERSION)
    response = llm.structured(
      role: :extract,
      schema: SCHEMA,
      schema_name: "nrc_decommissioning_licensees",
      crawl_run: run,
      reasoning_effort: "low",
      messages: [
        { role: "system", content: INSTRUCTIONS },
        { role: "user", content: text }
      ]
    )
    response.data.fetch("licensees")
  end

  private
    # Built on first use, so crawling never needs an OpenRouter key.
    def llm = @llm ||= DataQuality::OpenRouter::Client.new
end
