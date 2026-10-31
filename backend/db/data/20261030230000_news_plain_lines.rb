# PM, 30 Oct 2026: Latest showed the NRC's legal openers ("The U.S. Nuclear
# Regulatory Commission (NRC) is providing notice of…") and Holtec's blog
# openers. Each of the 17 published news items gets a plain headline (80
# characters at most) and a one-sentence summary (160 at most), written by
# Data Quality from that item's own stored text: no fact the text doesn't
# state. The title and the source's quote stay as they are. Merging this PR is
# Tosin's approval.
#
# Pinned: an item is changed only while its URL and title are still what was
# read on 30 Oct; one that differs is left and named. Idempotent: a rerun
# writes the same values and changes nothing.
class NewsPlainLines < DeployData::Migration
  BY = "human:tosin"
  # item id => what was read, and the plain lines
  ITEMS = {
    1 => { url: "https://www.federalregister.gov/documents/2026/10/05/2026-20345/tennessee-valley-authority-clinch-river-nuclear-unit-1-construction-permit-and-record-of-decision",
         title: "Tennessee Valley Authority; Clinch River Nuclear Unit 1; Construction Permit and Record of Decision",
         headline: "Construction permit and record of decision: Clinch River Nuclear Unit 1",
         summary: "The NRC issued TVA a construction permit for the Clinch River Nuclear Unit 1 reactor, with its record of decision." },
    2 => { url: "https://www.federalregister.gov/documents/2026/10/01/2026-20094/smr-llc-palisades-smr-llc-pioneer-units-1-and-2-phased-construction-permit-application-limited-work",
         title: "SMR, LLC; Palisades SMR, LLC; Pioneer Units 1 and 2; Phased Construction Permit Application-Limited Work Authorization",
         headline: "Phased construction permit application: Pioneer Units 1 and 2",
         summary: "The NRC gave public notice that Holtec's Palisades SMR filed the first part of a phased construction permit application and a work authorization request." },
    3 => { url: "https://www.federalregister.gov/documents/2026/09/25/2026-19603/constellation-energy-generation-llc-christopher-m-crane-clean-energy-center-environmental-assessment",
         title: "Constellation Energy Generation, LLC; Christopher M. Crane Clean Energy Center; Environmental Assessment and Finding of No Significant Impact",
         headline: "Environmental assessment: Christopher M. Crane Clean Energy Center",
         summary: "The NRC and DOE issued an environmental assessment and finding of no significant impact for the Crane Clean Energy Center's proposed federal actions." },
    4 => { url: "https://www.federalregister.gov/documents/2026/08/28/2026-17577/southern-nuclear-operating-company-vogtle-electric-generating-plant-units-1-and-2-independent-spent",
         title: "Southern Nuclear Operating Company; Vogtle Electric Generating Plant Units 1 & 2; Independent Spent Fuel Storage Installation; Exemption",
         headline: "Exemption: Vogtle Electric Generating Plant Units 1 & 2",
         summary: "The NRC allowed Southern Nuclear to keep one neutron source assembly in its current storage cell at Vogtle Units 1 and 2, a one-time exemption." },
    5 => { url: "https://www.federalregister.gov/documents/2026/08/28/2026-17626/smr-llc-palisades-smr-llc-pioneer-units-1-and-2-exemption",
         title: "SMR, LLC; Palisades SMR, LLC; Pioneer Units 1 and 2; Exemption",
         headline: "Exemption: Pioneer Units 1 and 2",
         summary: "The NRC approved Holtec's request to build permanent excavation support walls for Pioneer Units 1 and 2 before a limited work authorization is issued." },
    6 => { url: "https://www.federalregister.gov/documents/2026/08/27/2026-17529/nextera-energy-inc-dominion-energy-inc-virginia-electric-and-power-company-dominion-energy-nuclear",
         title: "NextEra Energy, Inc.; Dominion Energy, Inc.; Virginia Electric and Power Company; Dominion Energy Nuclear Connecticut; Dominion Energy South Carolina, Inc.; Surry Power Station, Unit Nos. 1 and 2; North Anna Power Station, Unit Nos. 1 and 2; Virgil C. Summer Nuclear Station, Unit 1; Millstone Power Station, Units 1, 2, & 3; North Anna Unit 3; North Anna Early Site Permit; and the Associated Independent Spent Fuel Storage Installations; Consideration of Approval of Transfer of Licenses",
         headline: "License transfer application",
         summary: "The NRC received and is considering an application from NextEra Energy and Dominion companies, filed on 15 July 2026, to approve a transfer of licenses." },
    7 => { url: "https://www.federalregister.gov/documents/2026/08/26/2026-17408/stp-nuclear-operating-company-south-texas-project-unit-1-license-amendment-application",
         title: "STP Nuclear Operating Company; South Texas Project, Unit 1; License Amendment Application",
         headline: "License amendment application: South Texas Project, Unit 1",
         summary: "The NRC is considering a license amendment for South Texas Project Unit 1, whose license is held by STP Nuclear Operating Company and others." },
    8 => { url: "https://www.federalregister.gov/documents/2026/08/25/2026-17253/smr-llc-palisades-smr-llc-pioneer-units-1-and-2-environmental-assessment-and-finding-of-no",
         title: "SMR, LLC; Palisades SMR, LLC; Pioneer Units 1 and 2; Environmental Assessment and Finding of No Significant Impact",
         headline: "Environmental assessment: Pioneer Units 1 and 2",
         summary: "The NRC issued an environmental assessment and finding of no significant impact for the Palisades SMR excavation support exemption at Pioneer Units 1 and 2." },
    9 => { url: "https://holtecinternational.com/hh-47-17/",
         title: "Palisades Begins the Process for Loading Fuel in its Reactor Vessel, Embarking on a Meticulous Progression to Restart: Holtec’s Finest Hour",
         headline: "Palisades begins loading fuel into its reactor vessel",
         summary: "Holtec said Palisades began loading nuclear fuel into the reactor vessel, a step in returning the shuttered plant to power generation." },
    10 => { url: "https://holtecinternational.com/hh-41-19/",
         title: "Holtec Nuclear Corporation Announces Launch of Initial Public Offering",
         headline: "Holtec Nuclear launches its initial public offering roadshow",
         summary: "Holtec Nuclear Corporation launched the roadshow for a proposed offering of 50,000,000 Class A shares." },
    11 => { url: "https://holtecinternational.com/hh-41-20/",
         title: "NRC Grants Holtec Exemption to Begin Early Site Construction Activities for Pioneer Units 1 and 2",
         headline: "NRC grants Holtec exemption for early site work at Pioneer Units 1 and 2",
         summary: "The NRC let Holtec start early site work, including digging and ground improvement, for two planned reactors at Palisades." },
    12 => { url: "https://holtecinternational.com/hh-41-21/",
         title: "Holtec Nuclear Corporation Initial Public Offering Postponed",
         headline: "Holtec Nuclear postpones its initial public offering",
         summary: "Holtec has postponed its planned stock offering after talks with its banks." },
    13 => { url: "https://holtecinternational.com/hh-41-22/",
         title: "Progress Report on Palisades’ March to Startup",
         headline: "Holtec's Palisades progress report on the march to startup",
         summary: "Holtec said Palisades continues fuel-loading work, plant testing and restoration, and preparations for the next stages of startup." },
    14 => { url: "https://holtecinternational.com/hh-41-23/",
         title: "Major Regulatory Developments in the Palisades Pioneer Unit 1 & 2 Program",
         headline: "Holtec's Pioneer Units 1 and 2 safety report goes to the NRC",
         summary: "Holtec's safety report gives the NRC technical and safety information for its application to build two SMR-300 reactors at Palisades in Michigan." },
    15 => { url: "https://holtecinternational.com/hh-41-24/",
         title: "Holtec’s Engineering and Manufacturing Prowess Delivers Breakthrough Fuel Assembly Recovery at Palisades",
         headline: "Holtec recovers a tilted fuel assembly at Palisades",
         summary: "Holtec said it recovered the tilted fuel assembly at Palisades using a purpose-built Fuel Movement Device made in two weeks." },
    16 => { url: "https://holtecinternational.com/hh-41-25/",
         title: "U.S. Energy Secretary Chris Wright Visits Palisades, Recognizes Progress Toward Historic Nuclear Restart",
         headline: "U.S. Energy Secretary Chris Wright visits Palisades",
         summary: "Energy Secretary Chris Wright visited Holtec's Palisades plant and, in Holtec's words, celebrated progress toward its restart." },
    17 => { url: "https://www.sargentlundy.com/news/providing-expertise-to-support-24-month-fuel-cycle-extension/",
         title: "Providing Expertise to Support 24-Month Fuel Cycle Extension",
         headline: "Sargent & Lundy on 24-month fuel cycle extensions",
         summary: "Sargent & Lundy shared insights on instrument setpoint calculations for longer fuel cycles with a nuclear plant standards committee." }
  }.freeze

  def up
    changed = 0
    ITEMS.each do |id, item|
      news = NewsItem.find_by(id:)
      next say("News item #{id} is gone") if news.nil?
      next say("News item #{id} left as it is: it is no longer published") unless news.verification_status == "verified"
      next say("News item #{id} left as it is: its url or title changed") unless news.url == item[:url] && news.title == item[:title]
      next if news.headline == item[:headline] && news.summary == item[:summary]

      result = Directory::FactWriter.write("news_item", { id:, headline: item[:headline], summary: item[:summary] },
        verification: { status: "verified", by: BY, reason: }, protect_human_verified: false)
      raise "news item #{id}: #{result.errors.to_sentence}" unless result.ok?

      changed += 1
      say "News item #{id}: #{item[:headline]}"
    end
    say "Gave #{changed} news items a plain headline and summary"
  end
end
