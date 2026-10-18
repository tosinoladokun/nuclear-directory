# The groups visitors browse by on the home page and the directory: the
# nine buckets of companies (docs/DATA.md section 4, #281), plus Plants and
# sites. A category is presentation only: which companies are in a bucket is
# computed from published roles and links (Bucket), never stored.
#
#   Category.all          # in display order
#   Category.find("fuel") # => Category or nil
#
# key is the URL slug and never changes once launched: a bucket that took
# over an older category keeps its slug ("fuel" for Fuel and materials).
# name is the short heading; title is the page's <title>, in the words people
# search with (#290); about is what the count in the description counts:
# "11 companies designing reactors or developing new nuclear plants in the US".
# role_keys are the roles that put a company in the bucket (child roles
# count through their parent); links names the rule for the links that do
# (Bucket).
Category = Data.define(:key, :name, :title, :about, :role_keys, :links, :plants, :short) do
  def self.all = self::ALL
  def self.find(key) = self::ALL.find { |category| category.key == key.to_s }
  def self.buckets = self::ALL.reject(&:plants)

  def initialize(key:, name:, title:, about:, role_keys: [], links: nil, plants: false, short: nil)
    super
  end

  # The label where only a short one fits (a chip on a phone, a home card):
  # approved by Tosin, 17 Oct. The full name stays in titles and aria-labels.
  def short_name = short || name

  def to_param = key

  # One plain sentence with the count, for the meta and link-preview
  # description: "11 companies designing reactors or developing new nuclear
  # plants in the US, including small modular reactors and fusion." It says what's on the page, not how
  # it's sourced (Tosin, #249). With fewer than two, the same words uncounted.
  def description(count)
    "#{count.to_i > 1 ? "#{count} #{about}" : about.upcase_first}."
  end
end

class Category
  # Display order (DATA.md): where only one label fits, a company shows the
  # first of its buckets in this order. Plants and sites sits with the
  # utilities that run them.
  ALL = [
    # Tosin, 16 Oct: reactor designers and the companies developing new
    # nuclear plants. The slug predates the rename and stays.
    new(key: "reactor-developers", name: "Developers", role_keys: %w[reactor_vendor project_developer],
      title: "Nuclear reactor and project developers in the US",
      about: "companies designing reactors or developing new nuclear plants in the US, including small modular reactors and fusion"),
    new(key: "fuel", name: "Fuel and materials", role_keys: %w[fuel coolant isotopes],
      title: "Uranium, nuclear fuel and materials suppliers in the US",
      about: "companies supplying uranium, nuclear fuel, coolant and isotopes in the US"),
    new(key: "components", name: "Components and manufacturing", short: "Components", role_keys: %w[components],
      title: "Nuclear component manufacturers in the US",
      about: "companies making equipment for US nuclear plants, from pumps and valves to instrumentation"),
    new(key: "waste-decommissioning", name: "Waste and decommissioning", short: "Waste", role_keys: %w[waste_decommissioning],
      title: "Nuclear waste and decommissioning companies in the US",
      about: "companies storing and moving spent fuel and decommissioning US nuclear plants"),
    new(key: "utilities", name: "Utilities and operators", short: "Plant operators", role_keys: %w[utility operator], links: :operating_plants,
      title: "US nuclear utilities and plant operators",
      about: "utilities and companies that own or run US nuclear power plants"),
    # Every kind of site: power plants, test reactors, fuel plants, mines (VOICE.md).
    new(key: "plants", name: "Plants and sites", plants: true,
      title: "US nuclear power plants and sites: owners and operators",
      about: "US nuclear power plants, test reactors, fuel plants and mines, with their owners and operators"),
    new(key: "power-buyers", name: "Power buyers", role_keys: %w[data_center_offtaker], links: :power_deals,
      title: "Companies buying nuclear power in the US",
      about: "companies buying nuclear power in the US, such as data center operators"),
    new(key: "services", name: "Services and engineering", short: "Services", role_keys: %w[reactor_services regulatory_consultant],
      title: "Nuclear services and engineering companies in the US",
      about: "companies that service US nuclear plants or help the industry with engineering and licensing"),
    new(key: "investors", name: "Investors", role_keys: %w[venture_capital], links: :investments,
      title: "Investors in US nuclear and fusion companies",
      about: "investors in US nuclear and fusion companies"),
    # Independent research organizations such as EPRI too (Tosin, 17 Oct).
    new(key: "government-research", name: "Government and research", short: "Government", role_keys: %w[government_agency national_lab university research_organization],
      title: "US nuclear agencies, labs and research organizations",
      about: "government agencies, national labs, universities and research organizations in US nuclear energy")
  ].freeze
end
