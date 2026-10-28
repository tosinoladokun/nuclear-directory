# Design's 27 Oct audit (PM): sources with no title showed their bare web
# address in "from these sources" (Google, TerraPower, BWXT and others, 111 in
# all). Each gets the title its own page carries (its <title>, trimmed of the
# site's repeated tagline), read from the page on 28 Oct 2026. Only a source
# with no title and this exact address is touched; a title already set is
# never changed. SEC filings (no fetch from here) keep their address.
# Merging this PR is Tosin's approval.
class SourceTitlesFromPages < DeployData::Migration
  BY = "human:tosin"
  TITLES = {
    "https://www.constellationenergy.com/newsroom/2024/Constellation-to-Launch-Crane-Clean-Energy-Center-Restoring-Jobs-and-Carbon-Free-Power-to-The-Grid.html" => "Constellation to Launch Crane Clean Energy Center, Restoring Jobs and Carbon-Free Power to The Grid",
    "https://www.constellationenergy.com/newsroom/2025/constellation-meta-sign-20-year-deal-for-clean-reliable-nuclear-energy-in-illinois.html" => "Constellation, Meta Sign 20-Year Deal for Clean, Reliable Nuclear Energy in Illinois",
    "https://www.converdyn.com/" => "ConverDyn - Global Provider of Uranium Hexafluoride (UF6)",
    "https://kairospower.com/external_updates/google-and-kairos-power-partner-to-deploy-500-mw-of-clean-electricity-generation/" => "Google and Kairos Power Partner to Deploy 500 MW of Clean Electricity Generation | Kairos Power",
    "https://kairospower.com/" => "Kairos Power | Advanced Nuclear Reactor Technology",
    "https://lowercarboncapital.com/" => "Lowercarbon Capital",
    "https://neutrons.ornl.gov/hfir" => "High Flux Isotope Reactor – Neutrons User Facilities",
    "https://urenco.com/news/usa/2024/leu-enrichment-award-u.s-department-of-energy" => "Urenco USA Selected for LEU Enrichment Award by U.S. DOE",
    "https://www.converdyn.com/contact-us" => "Get In Touch - ConverDyn",
    "https://www.converdyn.com" => "ConverDyn - Global Provider of Uranium Hexafluoride (UF6)",
    "https://www.converdyn.com/about-us" => "About Our UF6 Conversion Company - ConverDyn",
    "https://www.generalmatter.com/news" => "Milestones | General Matter",
    "https://www.holtecinternational.com/contact/" => "Get in Touch With Us - Holtec International",
    "https://kairospower.com/company/" => "About | Kairos Power",
    "https://lowercarboncapital.com" => "Lowercarbon Capital",
    "https://about.meta.com/company-info/" => "Company Info | Meta",
    "https://www.solstice.com/us/en/applications/nuclear-energy-services" => "Nuclear Energy Solutions & Fuel Services | Solstice",
    "https://talenenergy.com" => "Homepage - Talen Energy",
    "https://www.westinghousenuclear.com/contact-us" => "Contact Us | Westinghouse Nuclear",
    "https://ans.org/news/article-4444/just-add-haleu-terrapower-and-gnfa-break-ground-on-fast-reactor-fuel-facility" => "Just add HALEU: TerraPower and GNF-A break ground on fast reactor fuel facility -- ANS / Nuclear Newswire",
    "https://newsroom.kiewit.com/?p=10882" => "Energy Northwest Selects Design Builder for Cascade Advanced Energy Facility - Kiewit Corporation",
    "https://www.investor.nexteraenergy.com/news-and-events/news-releases/2025/10-27-2025-203948689" => "NextEra Energy and Google Announce New Collaboration to Accelerate Nuclear Energy Deployment in the U.S. – NextEra Energy, Inc.",
    "https://www.aboutamazon.com/news/sustainability/amazon-nuclear-small-modular-reactor-net-carbon-zero" => "Amazon enlists nuclear small modular reactors in push for net carbon-zero",
    "https://www.blueenergy.co/" => "Nuclear Power Designed to Scale | Blue Energy",
    "https://www.crusoe.ai/resources/newsroom/blue-energy-and-crusoe-partner-to-develop-nuclear-powered-ai-data-center" => "Blue Energy & Crusoe to build nuclear AI campus | Crusoe",
    "https://www.elementlpower.com/faq" => "FAQ — Elementl Power",
    "https://entra1.com/" => "ENTRA1 Energy | Powering Energy Security",
    "https://www.equinix.com/about" => "About Us | Global Platform for Digital Infrastructure | Equinix",
    "https://investor.equinix.com/news-events/press-releases/detail/1079/equinix-collaborates-with-leading-alternative-energy" => "Equinix Collaborates with Leading Alternative Energy Providers to Power AI-Ready Data Center Growth :: Equinix, Inc. (EQIX)",
    "https://blog.google/feed/google-and-elementl-nuclear-energy-site-development/" => "Google and Elementl Power are collaborating to advance nuclear energy site development.",
    "https://www.georgiapower.com/news-hub/press-releases/agreement-with-google-provides-$900-million-customer-benefits-advances-nuclear-energy.html" => "Georgia Power agreement with Google to provide approximately $900 million in projected benefits for customers and advance nuclear energy in Georgia",
    "https://www.lastenergy.com/" => "Last Energy | 20 MWe SMR | Fully modular, factory made",
    "https://www.lastenergy.com/about" => "Last Energy | Company Page",
    "https://newerainfra.ai/" => "New Era Energy and Digital",
    "https://www.nuscalepower.com/about" => "About Us | NuScale Power",
    "https://www.oklo.com/about/company-overview" => "Company Overview | Oklo",
    "https://www.oracle.com/news/announcement/oracle-announces-commitment-to-absorb-rising-point-beach-energy-costs-2026-10-02/" => "Oracle Announces Commitment to Absorb $300 Million in Rising Point Beach Energy Costs for Wisconsin Residents",
    "https://prometheushyperscale.com/about-us" => "About Us | PrometheusHyperscale",
    "https://www.energy.gov/ne/articles/radiant-completes-study-first-kaleidos-microreactor-experiment" => "Radiant Completes Study for First Kaleidos Microreactor Experiment | Department of Energy",
    "https://www.kairospower.com/updates/kairos-power-and-samsung-c-t-agree-to-pursue-strategic-investment-and-collaboration-for-kp-fhr-deployment" => "Kairos Power and Samsung C&T Agree to Pursue Strategic Investment and Collaboration for KP-FHR Deployment | Kairos Power",
    "https://www.switch.com/about/" => "Switch is a Global Technology Solutions Company",
    "https://www.switch.com/?p=33894" => "Oklo and Switch Form Landmark Strategic Relationship to Deploy 12 Gigawatts of Advanced Nuclear Power",
    "https://www.arc-cleantech.com/about" => "About | ARC Clean Technology",
    "https://www.arc-cleantech.com/" => "ARC Clean Technology | Mission-Critical Energy",
    "https://southernnuclear.com/our-plants/plant-farley.html" => "Farley Nuclear Power Plant | Joseph M. Farley Station",
    "https://www.alabamapower.com/our-company.html" => "Company",
    "https://www.alabamapower.com/" => "Alabama Power | Reliable Energy for a Growing Alabama",
    "https://www.ampeers.com/about" => "AMPeers - About",
    "https://www.ampeers.com/blog/hts" => "High performance HTS Tape",
    "https://www.ams-corp.com/who-we-are/" => "Who We Are - AMS",
    "https://www.aqwest.com/" => "Homepage - Aqwest",
    "https://www.aspisotopes.com/" => "Home - ASP Isotopes",
    "https://www.aspisotopes.com/quantum-leap-energy" => "Quantum Leap Energy | Materials that power the future",
    "https://www.terrapower.com/terraPower-announces-strategic-agreement" => "TerraPower Announces Strategic Agreement to Commercialize and Purchase HALEU",
    "https://bluewaveailabs.com/about/" => "About Blue Wave AI Labs - Innovation in AI for Smart Energy",
    "https://bluewaveailabs.com/" => "Nuclear-Grade AI™ Applications - Blue Wave AI Labs",
    "https://www.bridge12.com/" => "Bridge12 | Microwave and Terahertz Sources for Nuclear … | Bridge12",
    "https://brookhaventech.com/" => "Brookhaven Technology Group – Energy Research and Development",
    "https://brookhaventech.com/customers/" => "Customers – Brookhaven Technology Group",
    "https://www.bwxt.com/" => "BWXT",
    "https://www.bwxt.com/sectors/nuclear-fuel/" => "Nuclear Fuel",
    "https://www.bwxt.com/sectors/nuclear-energy/components-equipment/" => "Components & Equipment",
    "https://ctp-usa.com/about/" => "About Us",
    "https://ctp-usa.com/" => "Home",
    "https://containertechnologies.com/" => "Container Technologies Industries",
    "https://europe.epri.com/" => "Homepage | EPRI Europe",
    "https://nuclearplantmod.epri.com/Nuclear_Plant_Modernization_Toolbox" => "Plant Modernization Toolbox",
    "https://www.ensco.com/news-media/press-releases/us-department-of-energy-awards-contract-to-ensco-to-build-and-test-fortis-railcar" => "U.S. Department of Energy Awards Contract to ENSCO to Build and Test Fortis Railcar | ENSCO",
    "https://www.fpl.com/about/company-profile.html" => "FPL | Company Profile",
    "https://www.govinfo.gov/content/pkg/FR-2025-05-16/html/2025-07729.htm" => "Federal Register, Volume 90 Issue 94 (Friday, May 16, 2025)",
    "https://www.nacintl.com/solutions/storage-technologies" => "Storage Technologies | NAC International",
    "https://www.bwxt.com/sectors/nuclear-fuel/nuclear-fuel-services/" => "Nuclear Fuel Services",
    "https://nusenics.com/" => "Nusenics | Fiber-optic sensing for extreme environments",
    "https://plasmapros.com/" => "Home - Plasma Processes",
    "https://plasmapros.com/markets/department-of-energy-doe-and-energy/" => "Department of Energy (DOE) and Energy - Plasma Processes",
    "https://www.sbir.gov/portfolio/15610" => "Firm | SBIR",
    "https://www.sbir.gov/portfolio/405296" => "Firm | SBIR",
    "https://oceanatomics.com" => "Ocean Atomics",
    "https://www.curtisswright.com/contact-us" => "Curtiss-Wright Corporation | Contact Us | Corporate Office",
    "https://www.curtisswright.com/news/press-releases/news-release-details/2026/Curtiss-Wright-Installs-Stage-1-Simulator-at-TerraPower-Natrium-Site-in-Kemmerer-WY" => "Curtiss-Wright Installs Stage 1 Simulator at TerraPower’s Natrium Site in Kemmerer, WY | Curtiss-Wright Corporation",
    "https://electro-mechanicalsystems.curtisswright.com/emd/markets-and-products/power-products-and-services" => "EMD - Markets & Products - Power Products & Services | EMS",
    "https://holtecinternational.com/company/divisions/hdi/" => "Holtec Decommissioning International - Holtec International",
    "https://www.sce.com/about-us/who-we-are" => "About SCE | SCE",
    "https://www.bnl.gov/about/" => "BNL | About Brookhaven National Laboratory",
    "https://www.pnnl.gov/" => "Pacific Northwest National Laboratory | PNNL",
    "https://news.duke-energy.com/releases/duke-energy-florida-launches-new-solar-site-in-jefferson-county" => "Duke Energy Florida launches new solar site in Jefferson County | Duke Energy | News Center",
    "https://www.terrapower.com/terrapower-and-sabey-data-centers-agreement-for-natrium-wide-scale-deployment" => "TerraPower and Sabey Data Centers Developing Strategic Collaboration Agreement for Wide-Scale Deployment of Natrium® Plants",
    "https://www.blueenergy.co" => "Nuclear Power Designed to Scale | Blue Energy",
    "https://cfs.energy/" => "Home | Commonwealth Fusion Systems",
    "https://www.nuscalepower.com/" => "NuScale Power | Small Modular Reactor (SMR) Nuclear Technology",
    "https://typeoneenergy.com/" => "Home - Type One Energy",
    "https://westinghousenuclear.com/energy-systems/" => "New Nuclear Power Plants | Westinghouse Nuclear",
    "https://www.advancedconductor.com/" => "Advanced Conductor Technologies LLC",
    "https://cfs.energy/technology/sparc/" => "SPARC: Proving commercial fusion energy is possible | Commonwealth Fusion Systems",
    "https://cfs.energy/news-and-media/eni-and-commonwealth-fusion-systems-sign-1-billion/" => "Eni and Commonwealth Fusion Systems Sign $1 Billion+ Power Purchase Agreement, Expanding Strategic Partnership To Commercialize Fusion Energy | Commonwealth Fusion Systems",
    "https://www.ga.com/triga" => "TRIGA® Research Test Reactors | General Atomics",
    "https://www.gle-us.com/about" => "About Global Laser Enrichment",
    "https://www.goodenergycollective.org/" => "Good Energy Collective | Nuclear Energy Policy Research",
    "https://www.pkmj.com/" => "PKMJ Technical Services LLC",
    "https://www.nuscalepower.com/press-releases/2026/nuscale-power-reports-fourth-quarter-and-full-year-2025-results" => "NuScale Power Reports Fourth Quarter and Full Year 2025 Results",
    "https://www.h3dgamma.com/" => "H3D, Inc.",
    "https://www.nasa.gov/centers-and-facilities/glenn/sr-1-freedom-advances-with-progress-on-nuclear-power-module/" => "NASA’s SR-1 Freedom Advances with Progress on Nuclear Power Module - NASA",
    "https://www.nasa.gov/" => "NASA",
    "https://antaresindustries.com/" => "Antares Nuclear: Factory-Produced Fission Microreactors for Strategic Energy",
    "https://antaresindustries.com/updates/antares-janus" => "Antares"
  }.freeze

  def up
    set = 0
    TITLES.each do |url, title|
      source = Source.find_by(url:)
      next if source.nil? || source.title.present?

      source.update_columns(title:, updated_at: Time.current)
      set += 1
    end
    say "Gave #{set} sources the title their page carries"
  end
end
