# DATA.md: what the directory records, and how

The rules for every fact in Nuclear Directory: what each record is, what each link means, how things are named, which units we use, what counts as a source, and which checks hold it all together. The seed files, the data quality pipeline (`DataQuality::`), the admin and every hand-researched addition follow it.

**The one rule:** every published fact has a public source and a quote that states it. If we can't source it, we don't publish it.

Sections 1–5 say what to record. Section 6 lists every rule as a check, marked **enforced** (the database or `Directory::FactWriter` refuses a violation) or **audited** (to be flagged by `data_quality:audit` and the admin's Live screen; both are planned, M10 and Admin v2, so today these are run by hand from the audit queries). Section 7 lists the decisions and who made them.

## 1. Records

### What each record is

| Record | What it is | Example | Not this |
|---|---|---|---|
| Company (`Organization`) | One company per brand (decision #23). Legal entities and subsidiaries named by sources become aliases, or a `subsidiary_of` link when a source states the parent | Constellation (aliases: Constellation Energy Generation, LLC) | A person, a project, a fund vehicle no source ties to the firm |
| Plant site (`Facility`, no parent) | A place: a power plant, fuel plant, mine, mill, test reactor or fusion plant | Plant Vogtle | A single reactor at a multi-unit plant |
| Reactor unit (`Facility` with a parent) | One reactor under its site: licensed, or planned with a unit its developer identifies ("Palisades Pioneer Unit 1") | Vogtle 3 | A design (AP1000), or a project with no identified unit |
| Plant link (`FacilityRelationship`) | A company's role at a plant | Southern Nuclear operates Vogtle 3 | A deal between two companies |
| Company link (`Relationship`) | A deal or tie between two companies | Centrus supplies TRISO-X | A role at a plant |
| Deal term (`DealTerm`) | One award, power deal or funding round under its link, with amount and dates; or a company's own funding round when its filing names no investors (Form D) | A DOE award (ID, amount, start date) under "DOE funds X-energy"; a Form D round on the company that raised it | The link itself |
| Licensing stage (`LicensingStage`) | One stage a reactor project or plant has reached with the NRC, with its docket and the date: pre-application, application accepted, construction permit, combined licence (Part 52), operating licence, restart under NRC review, restart approved, design approval, withdrawn or denied | Hermes 1: construction permit, 14 Dec 2023, 50-7513 | A press release's say-so; the current stage as one field that overwrites the last |
| Category (role) and technology | A tag on a company, each with its own quote | X-energy: reactor designer; SMR | A tag inferred without a quote |

### Site or unit

- **A unit** has an NRC docket (or, before licensing, a unit number the developer states) and sits under its site. Two levels only: site, then unit.
- **A site** has no parent. It holds the EIA plant ID, the location and the operator links. A single-unit plant can stand alone as one record until its EIA site exists (Columbia today).
- Unit capacity, coordinates and state come from EIA's generator row. A unit's state should equal its site's (audited).
- **In a company's seed file,** a link to one unit gives its site too: `- name: Indian Point 2` with `site: Indian Point`. The loader finds the site among sites by name (or makes it), then the unit under it by name (or makes it there). A same-name plant with no site becomes that unit; one already under another site fails the load. Write the site's name exactly as the directory has it (Indian Point, San Onofre, Duane Arnold Energy Center): a variant makes a second site. Without `site:`, the entry is a plant of its own, so use it only for a site or a single-unit plant.

### The same record

The pipeline and FactWriter find an existing record by these, in this order. A record that matches none is new:

| Record | Identity, strongest first |
|---|---|
| Unit | NRC docket; then a unit name or alias (e.g. a planned unit before it has a docket) |
| Site | EIA plant ID; then a site name or alias |
| Company | Its SEC CIK (`sec_cik`, 10 digits) when it has one; then its EIA utility ID (`eia_utility_id`, EIA-860's number for a utility or plant owner); then a normalized name or alias (`OrganizationAlias.normalize`: case, punctuation and Inc./LLC/Co. dropped); then the website domain, unless several companies share it. A same-brand match ("Duke Energy Carolinas, LLC" → Duke Energy) is used by matching only, to propose; it never merges on its own |
| Link | Both ends and the type |
| Deal term | The link (or, for a company's own round, the company), the term type and the external ID (award ID, or the original Form D's accession number) |
| Licensing stage | The unit that holds the docket, the docket and the stage; for a design approval, the developer, the design and the stage |

Coordinates are not an identity: two live sites within 50 m are flagged for a person (section 6), never matched automatically. Neighbouring plants within a kilometre (Salem and Hope Creek; Nine Mile Point and FitzPatrick) are different sites: never merge on distance alone. A duplicate is merged by a person, with `FactWriter.merge_organization` or `merge_facility`; the merged-away record keeps its history and its old address redirects.

## 2. Links

The verb is fixed (VOICE.md). Each link needs a quote that states that relationship, not just that the two names appear together.

### Plant links

| Type | On screen | Means | Example | Not this | Authoritative source |
|---|---|---|---|---|---|
| `operates` | operates | Runs the site day to day. For a power reactor: holds the NRC operating license. For other sites (mines, mills, enrichment, fuel and test facilities): named as operator by the operator, owner, NRC or another agency | Southern Nuclear operates Hatch 1; Ur-Energy operates Lost Creek | The utility that reports the plant to EIA (EIA's Entity Name is not the operator, #227) | NRC reactor list for power reactors; otherwise the operator's, owner's or an agency's page that names the operator |
| `owns` | owns | Holds an ownership share; `ownership_pct` only when the source states it | Oglethorpe Power owns Plant Vogtle (30%) | Leasing a site (state the lease in the description instead) | Owner filings, press releases, the operator's plant page |
| `vendor_for` | is the reactor developer for | Designed or supplies the reactor | Westinghouse is the reactor developer for Plant Vogtle | Supplying parts or services (use `supplies` to the operator) | Developer or operator press release, NRC docket |
| `offtakes_from` | offtakes from | Has agreed to buy the plant's power | Amazon offtakes from Susquehanna | A power deal with the company, not tied to a plant (use `offtake_with`) | The buyer's or seller's press release, SEC 8-K, utility commission filing |

### Company links

| Type | On screen | Means | Example | Not this |
|---|---|---|---|---|
| `supplies` | supplies | Provides fuel, equipment or services under a stated agreement | Centrus supplies TRISO-X (HALEU) | A memorandum with no supply (say "MOU" in the description, or wait) |
| `invests_in` | invests in | Takes equity | Amazon invests in X-energy | A grant or award (`funds`), or an investment only a LinkedIn post claims |
| `funds` | funds | Grants, awards, cost-shared programs and loans (Tosin, 26 Oct). A loan is always marked as one: the description quotes it ("$1.52 billion loan, closed September 2024") and, once the `loan` deal-term kind exists, its deal term says so | DOE funds X-energy (ARDP); DOE funds Holtec Palisades ($1.52 billion loan) | Equity |
| `offtake_with` | offtakes from | Agreed to buy power from the company's existing or future fleet | Meta offtakes from Constellation | A power deal tied to one plant (use the plant link `offtakes_from`) |
| `subsidiary_of` | is a subsidiary of | Points from the child to its parent | Georgia Power is a subsidiary of Southern Company | A partnership or joint venture |

**Deal stage** goes in the deal term (#256): its `agreement` (`ppa`, `supply_agreement`, `tariff_subscription`, `development_agreement`, `prepayment`, `framework`, `mou`, `loi`, `option` or `preorder`) and its `status` (`announced`, `signed`, `active`, `completed` or `terminated`). A **counted** deal is a PPA, supply agreement or tariff subscription that's signed, active or completed, with no open `conditions` (an approval it still waits for, named: "NRC approval", "Georgia PSC approval"); one with a condition shows as signed, pending. Development agreements, prepayments, frameworks, MOUs, letters of intent, options and preorders are listed by stage, never counted. Funding and equity are funding terms, not offtakes, and have no agreement. `capacity_mw` is the headline MW; `firm_mw` is what's firmly contracted, blank when the source doesn't state it (never estimated); `term_years` is the length when a source gives no dates. A deal listed by stage may state no MW. The link's description still says it in words, but amounts, MW and dates are deal terms, never free text alone. In the seed, each agreement is a `terms:` entry under its link, with a stable `key` (e.g. `google-kairos-mpda-2024`).

**Funding rounds from Form D (PM, 18 Oct, #129):** a Form D states a round's amount sold, the amount offered and the date of first sale, but names no investors. It's recorded as a funding round on the company itself (`amount_usd` = sold, `amount_offered_usd` = offered, `starts_on` = first sale, `external_id` = the original filing's accession number, so a Form D/A amends the same round). It's never recorded as a link to a placeholder such as "undisclosed investors". An investor named by another primary source is a separate `invests_in` or `funds` link. A company's own round counts toward the company's funding, never toward an investor's total.

**Counting deals (Tosin, 15 Oct: "just facts, not opinions"):**
- A **deal** in counts and data pieces is a **signed** power deal: a PPA, a supply agreement or a tariff subscription.
- **Frameworks, MOUs, letters of intent, options and preorders** are recorded too, but listed separately and labelled by stage. They're never in the headline count.
- **Self-builds** (a company buying reactors for its own site) and **feasibility studies** are not power deals.
- An **unnamed party** stays unnamed ("a hyperscaler", as its filing says). A deal reported only by trade press, or only as talks, is not recorded until a primary source states it.

## 3. Names

- **Company display name: the brand the company uses** on its own site ("Constellation", "Duke Energy", "Ameren"). Every legal name and source spelling ("Constellation Energy Generation, LLC", EIA's "Union Electric Co - (MO)") is saved as an alias, so matching still finds it. *(Tosin, D1.)*
- **Aliases have a kind** *(recommended; needs a small schema change, #267)*:

  | Kind | Means | On the company page | Needs |
  |---|---|---|---|
  | `name` | Another current name: abbreviation, product brand, regional brand ("ODEC", "Ameren Missouri") | "Also known as" | Nothing beyond the alias |
  | `legal` | A legal entity's registered name ("Southern Nuclear Operating Co., Inc.") | "Legal names" (collapsed) | Nothing beyond the alias |
  | `former` | A name the company used before a rename ("FirstEnergy Nuclear Operating Co.") | "Formerly …, until 2020" | A quote stating the rename, and the year it took effect |

  Matching treats all three the same. Only `former` changes what a page says, so only `former` needs its own source.
- **Plant display name: the operator's name for the plant** ("Plant Vogtle", "Susquehanna Steam Electric Station"). NRC and EIA spellings ("Vogtle", "TalenEnergy Susquehanna") become aliases.
- **Short name** (`short_name`, optional, up to 30 characters): a display label for tight spots (the connections map, home lists, chips, crumbs), preferably the company's own common usage: "Oglethorpe", "MEAG", "DOE", "Vogtle". **It's never an identity key and never matched on.** Matching uses the name and aliases; a short name a source uses goes in the aliases too. It needs no quote, since it labels a record rather than stating a fact, and a person sets it (seeds or the admin). *(PM, 18 Oct.)*
- **Unit names follow NRC's list** ("Vogtle 3", "Hope Creek 1"). A single-unit plant may share its unit's name ("Callaway").
- **Casing:** as the owner writes it. No all-caps unless it's an acronym (TVA, NRC). Keep accents and en dashes as published ("Global Nuclear Fuel–Americas").
- **Abbreviations** are aliases, not display names: "NCP", "INL", "GNF-A".
- **Slugs** come from the display name, lowercase with hyphens. A rename or merge keeps the old slug as a redirect (#143). Never reuse a slug.
- **The source's spelling never renames a record.** A new spelling is shown to a person ("the source calls it …") to add as an alias or rename on purpose.

## 4. Values and units

| Field | Rule |
|---|---|
| Capacity | **MW, net summer**, from EIA-860M's "Net Summer Capacity (MW)", stored to 0.1 MW. Shown as "MW", with the note "Net summer capacity, from EIA" on plant pages (Tosin, D2). Nameplate is never mixed in. A site's capacity is the sum of its units, never stored. |
| Plant status | `operating`, `not_operating`, `under_construction`, `planned`, `shut_down`, `decommissioning`. Blank means not stated, shown as "Not stated". Never guessed. A power reactor is `operating` if NRC lists it and its daily status report shows power above 0% on at least one of the last 365 days; a refuelling outage doesn't change that. It's `not_operating` ("Not operating") if it's licensed but at 0% on all 365 days, like Palisades in 2026. That isn't permanent, which is `shut_down`. A restart plan goes only in a sourced note (#296) |
| Company status | `active`, `acquired`, `defunct`, each with a quote when it isn't `active` |
| Dates | ISO `2026-10-09` in data. A month-only source date is stored as the 1st, with the description saying "October 2026" |
| State | Two-letter USPS code. For power plants in EIA-860M, from EIA (not NRC's "nearest city", which put Salem in Delaware, #197). For any other site (test reactors, fuel plants, mines, fusion plants), from the operator's, owner's or an agency's page that states it (e.g. HFIR from DOE OSTI) |
| Location | "City, ST" when a source names the city (#225). Coordinates to 6 decimal places: from EIA for power plants it covers; otherwise from an official record (NRC, DOE, a state agency) that states them. None rather than geocoding an address |
| Country | ISO 3166 alpha-2, only when a source states where the company is based. Blank otherwise |
| Ownership | Percent, 0–100, only on `owns`, only as stated. Co-owners' shares should sum to 100 or less |
| Money | US dollars in deal terms (`amount_usd`). Other currencies are converted only if the source gives the figure |
| Category (role) | See "Buckets and tags" below. One quote per category, saying what the company does |
| Technology | `fission`, `fusion`, `smr` today. Planned design types (roadmap, #263): `molten_salt_reactor`, `htgr`, `sodium_fast`, `microreactor`, `light_water_smr`, tagged only from a source that states the design |

### Location, short descriptions and short names (Design, 26 Oct)
- **Location is only what a source states.** A city needs its state (a US company) or its country in a quote that says it, such as "Alameda, California United States". `country_code` stays blank unless a source states it. Never fill a state or country from a nearby fact, the company's other offices or what's likely.
- **`short_description`** is a noun phrase of at most 40 characters, no final full stop, no company name, no hype: "Uranium mining in Wyoming", not "Mines uranium". It is sourced like the description, with a quote that supports it.
- **`short_name`** is a display label for a long legal or registered name, only where the company itself uses the short form. It never replaces the name and is never a source of identity.
- **A company with no current role** (defunct, or absorbed) gets status `acquired` or `defunct`, backed by a primary-source quote, so it leaves the lists. It is never given a role it doesn't have.

### Buckets and tags (Tosin, 15 Oct; #263, #267)

**Scope: the whole US nuclear industry, not only power** (Tosin): fission and fusion, fuel, isotopes, equipment, waste, services, buyers, investors and research.

**A company sits in every bucket its sourced categories and links support.** Westinghouse is in Developers, Fuel and materials, and Services and engineering; Amazon is in Power buyers and Investors. A bucket is never stored and never chosen by a person: it's computed from facts that already have sources, so it can't drift from them. **Tags** carry the finer detail (venture capital, SMR, molten salt, fuel-cycle stage) for filters and explanations.

**The 9 buckets** (a bucket with no companies stays hidden; industry groups become the 10th with #162; counts from 15 Oct):

| Bucket | Means | A company is in it when it has | Today |
|---|---|---|---|
| Power plant owners and operators | Owns or runs nuclear power plants. Its slug stays `utilities` | `utility` or `operator`, or a published owns/operates link to an **operating power plant** | 33 |
| Developers (home card: Reactor Developers) | Builds new nuclear: designs or sells reactors (fission or fusion), or develops, finances and will own or run new nuclear plants. Its slug stays `reactor-developers`. One category, told apart by the role shown on each company: **Reactor designer** (`reactor_vendor`, designs the reactor) and **Project developer** (`project_developer`, builds and develops plants); a company with both shows both (Tosin, 21 Oct) | `reactor_vendor` or `project_developer` | 19 |
| Fuel and materials | Mines, converts, enriches or fabricates fuel; ships fresh fuel; supplies materials such as coolant; produces isotopes (medical and industrial) | `fuel` or its stages, `coolant` or its kinds, `isotopes` (new key), or the sourced tag "fresh-fuel transport" | 11 |
| Components and manufacturing | Makes equipment: pumps, valves, forgings, steam generators, instrumentation and control hardware, naval and defense nuclear components | `components` (new key) | 0 |
| Waste and decommissioning | Stores, transports and disposes of spent fuel and waste; decommissions plants | `waste_decommissioning` (new key), or the sourced tag "spent-fuel transport" | 0 |
| Services and engineering | Maintains, builds, licenses or advises, and other professional services to the industry | `reactor_services`, `regulatory_consultant`, or a sourced activity tag: construction (EPC), licensing and consulting, legal, insurance, software | 6 |
| Power buyers | Buys nuclear power, mostly hyperscalers and data centers | `data_center_offtaker`, or a published power deal as the buyer, **unless the buyer is a utility** (TVA buying from Kairos is a utility deal) | 4 |
| Investors | Puts money into nuclear companies or projects | `venture_capital`, a sourced investor-type tag (private equity, bank, project finance, corporate fund), or a published `invests_in` or `funds` link as the funder, **unless the funder is a government agency** (DOE grants put DOE in Government and research, not Investors) | 9 |
| Government and research | Agencies, regulators, national labs, universities and independent research organizations | `government_agency`, `national_lab`, `university`, `research_organization` | 4 |

**Counting:** buckets overlap (6 of 81 companies are in two or more today). The total is always the number of companies ("81 companies"), never the sum of buckets. A bucket count is labelled "companies that develop reactors", "companies that buy nuclear power", and so on. Charts of buckets are bars, never a pie or a 100% stack.

**One label, where only one fits:** cramped spots (link-preview cards, search results) show the company's first bucket in this display order: Developers, Fuel and materials, Components and manufacturing, Waste and decommissioning, Power plant owners and operators, Power buyers, Services and engineering, Investors, Government and research. It's for display only: never stored, counted or exported. The company's page and the dataset list all its buckets.

**Where edge cases go** (the bucket, then the tag that says more):

| Kind of company | Bucket | Tag |
|---|---|---|
| Construction and EPC contractors | Services and engineering | construction (EPC) |
| Licensing and engineering consultants | Services and engineering | licensing and consulting |
| Law firms, insurers | Services and engineering, only with a sourced nuclear role | legal, insurance |
| Software and digital (not hardware) | Services and engineering | software |
| Instrumentation and control hardware; naval and defense nuclear manufacturing | Components and manufacturing | — |
| Spent-fuel casks and their transport | Waste and decommissioning | spent-fuel transport |
| Fresh-fuel logistics | Fuel and materials | fresh-fuel transport |
| Medical and industrial isotope producers | Fuel and materials | isotopes |
| Private equity, banks, project finance | Investors | private equity, bank, project finance |
| Universities with research reactors or DOE awards | Government and research | university |

**Promoting a tag to a bucket:** when about 10 sourced companies carry a tag that isn't covered well by its bucket (isotopes is the likely first), it becomes its own bucket, with a decision by Tosin and a redirect for any changed URL.

**Tags, by group** (filters and explanations, never navigation):

| Group | Tags |
|---|---|
| Investor type | Venture capital, private equity, bank, project finance, corporate fund, each from a quote |
| Fuel-cycle stage | Uranium (mining and milling), conversion, enrichment, fabrication |
| Activity | Isotopes, fresh-fuel transport, spent-fuel transport (each from a quote that says which fuel it carries), construction (EPC), licensing and consulting, legal, insurance, software |
| Sector | University, national lab, agency |
| Technology | Fission, fusion, SMR (design types are on the roadmap, #263). Fusion is a tag under Developers, never its own bucket |
| Coolant | Molten salt, water, helium, sodium, lead, heavy water |
| From its links (computed) | Operates a plant, owns a plant, buys power, invests, has deals |

**New category keys:** `components`, `waste_decommissioning`, `isotopes` and `university` join the roles list, each given to a company only from a quote that states it (for example, Holtec's storage business once quoted).

**Stable URLs (Founder):** each bucket has a list page whose slug never changes once launched; a rename keeps the old URL as a redirect. Popular tags get shareable list pages too: `/companies?tag=fusion` and `/companies?tag=uranium`. The old fusion category URL redirects to the fusion tag page.

**What changes on the site:**
- Navigation shows the buckets that have companies (7 today) instead of 11 categories; a company appears under each of its buckets.
- Company pages show all of a company's buckets, then its tags.
- Public filters (#263) become "Type" (buckets, multi-select) plus the tag groups.
- 20 operators the crawlers created, which have no category, appear under Power plant owners and operators through their sourced links to operating power plants.
- The 13 companies in no bucket (duplicates and raw names, #230, #267) stay out of navigation until they're cleaned up.
- No database change beyond the two new category keys: buckets are a fixed mapping in code from category keys and links.
- The open dataset (#254) has one company per row, with buckets and tags as list columns; each category's source is in the facts export.

## 5. Sources and quotes

### What counts as a source

| Tier | What | Use |
|---|---|---|
| 1. Official record | NRC, EIA, DOE and other agency pages and data; SEC filings; state utility commission filings | Cite. Preferred for operators, licenses, capacity, awards |
| 2. The party itself | A company's own site, press release or annual report | Cite. Preferred for deals, products and descriptions |
| 3. Named reporting | Trade press or news that names both parties and the terms | Cite when tiers 1–2 don't state it; replace it with a primary source when one appears. **Not for deals:** a power deal, investment or award needs a tier 1–2 source (section 2) |
| Leads only | Aggregators and directories: SMR Intel, ANS Buyers Guide, GAIN directory, GEM tracker, WNA, LinkedIn | Never cite. Trace each lead to tiers 1–3 (#257–#259) |

**Which sources feed which bucket**, with what's live, planned or missing: the "Sources by bucket" table on the sources roadmap, #133 (https://github.com/tosinoladokun/nuclear-directory/issues/133#issuecomment-6206324347).

Not a source: anything behind a login or paywall, AI-written summaries, a page that only lists names together, and personal data of any kind.

**Licensing stages are stricter (#379):** only NRC records count, any page on nrc.gov (a project page, ADAMS) or an NRC notice in the Federal Register (on federalregister.gov, or its copy on govinfo.gov; other govinfo.gov publications, such as the Congressional Record, don't count). A licensing stage isn't seeded as pending: until stages can be reviewed in the admin, a lead stays out of the seed. A press release or a news article is a lead: it can be attached, but it never makes a stage public, and FactWriter refuses to verify a stage without an NRC record behind it.

### Quotes

- **The quote states the value.** "Oglethorpe Power (30%)" supports `owns 30%`; a page that only lists Oglethorpe as a partner doesn't.
- **Copied exactly** from the page's text, not from a summarizer. Short is fine; it has to contain the fact.
- **Derived values** (a site's total capacity, counts) aren't stored as facts. They're computed from sourced facts and shown as computed.
- **Every quote keeps its source's URL** and the date it was read. A source re-read nightly is stamped `last_confirmed_at` when it still says the same thing (#240). A person's decision always wins over a later source: a source that disagrees with a human-verified value goes to review, never overwrites it. A value counts as a person's unless the last write to it was an unedited approval from the same kind of source; then the source may update it, through the verifier and a person's approval like any claim.

## 6. Checks

The admin's Live screen and the nightly `data_quality:audit` are planned (Admin v2, M10). When built, both read the same definitions (#238 comments), so the screen and the report never disagree.

### Enforced (a write that breaks them is refused)

- **Identity:** unique company slug and domain; unique plant slug; unique NRC docket; one site per EIA plant ID; company aliases unique among companies, and plant aliases among plants; a plant alias is never another plant's name.
- **Links:** unique per ends and type; no self-links; both ends required (#226, #231); no automated link to a rejected or unpublished company or plant, or under a closed site; `ownership_pct` only on `owns`, 0–100.
- **Decisions:** only a person unpublishes, merges, or changes a fact that's already rejected or unpublished. The pipeline may reject only what it proposed itself. A human-verified value is never overwritten; a disagreement becomes a conflict for review. Every decision is an append-only history event; merges record `merged_into`.
- **Publishing:** a fact is public only through its model's `.published` scope: a unit when verified under an open site; a pending site when it has such a unit; a link only when both ends are public; a deal term only with its link.
- **Deal terms:** one term per link (or company), kind and award ID; an award needs an amount, a start date and an award ID; a term on a company itself is a funding round; dates in order; no negative amounts; no automated term on a rejected or unpublished link.
- **SEC CIK:** 10 digits, zero-padded, unique among companies.
- **EIA utility ID:** a plain number without leading zeros ("7140"), unique among companies. One company holds one; a brand with several EIA utilities (Duke Energy) keeps the one its owner claims use, and a second goes to review.
- **Licensing stages:** exactly one of a unit or a developer, and a developer only for a design approval, with its design named; one stage per unit, docket and stage; a stage is verified only from an NRC record; no automated stage under a rejected or unpublished plant or company. A developer also holds a project's pre-application docket (NRC 999xxxxx) or its withdrawal before the plant is in the directory, one row per developer, docket and stage; later stages go on the plant (#650).
- **First batches and Data Quality's list (PM, 22 Oct):** the Today screen's "accept the agreed" shortcut lifts a new source's first-batch hold when Data Quality's list has reviewed the claim. So Data Quality reads that list claim by claim for a new source's first batch, every quote, and never sends a bulk "accept" entry.

- **Read-only access:** Metabase's read-only role reads only the tables on `Metabase::ReadonlyRole::READABLE_TABLES`, never sign-in data, visitors' correction reports or the deploy's records. There are no default privileges. A migration that creates a public-data table adds it to the list and grants it (`Metabase::ReadonlyRole.grant!`); a test fails while any table is on neither list (PM and Data Quality, 18 Oct).

### Audited (planned: the Live screen and `data_quality:audit`, #277)

| Check | Severity | Rule |
|---|---|---|
| `no-quote` | Highest | A public fact with no quoted evidence |
| `ineligible-source` | Highest | A public fact with **no eligible evidence**: none of its quotes comes from a citable source (leads-only sources such as LinkedIn, SMR Intel, ANS Buyers Guide, GAIN, GEM and WNA never count), or, for a deal, investment or award, none comes from tier 1 or 2 (section 5). Mixed ineligible evidence (say LinkedIn plus news) is flagged. Uses a leads-only domain list and the news domains in #166's publisher lookup |
| `source-disagrees` | High | A source now states a different value, or a person's decision overrides one |
| `dropped-by-source` | High | A complete read of its source no longer lists it |
| `stale` | Medium | Not re-confirmed in 14 days (NRC, EIA) or 365 days (web, hand research) |
| duplicate site | High | Two live sites share an EIA plant ID or coordinates within 50 m |
| duplicate company | High | Two live companies share a normalized name, alias or domain |
| `single-source` | Low | Rests on one source |
| `unquoted-docket-place`, `unquoted-hq`, `unquoted-legal-name` | Low | A plant's docket or place, or a company's headquarters or legal name, that none of the record's own quotes states (#407). A docket or legal name must appear as written, case, spacing and dash style aside; a docket also counts in NRC's short forms (05000254 as "50-254" or "050-00254"). A place needs the city as written and the state as its code (in capitals), full name or AP abbreviation ("Tenn.", "N.C."), in one quote. The fact itself stays on the page: only the line under its key facts leaves it out of "from these sources". Also counted by `seed:check`, which doesn't fail on them |
| `idle-all-year` | High | A reactor marked `operating` that NRC's daily status report shows at 0% on all of the last 365 days (#296) |
| `no-operator` | Medium | An operating reactor or plant with no published operator, on it or its site |
| `no-capacity` | Medium | An operating reactor with no capacity |
| `no-location` | Medium | Any plant or reactor without coordinates or a state |
| `no-site` | Medium | Any reactor with an NRC docket that isn't under a site |
| `no-owner`, `no-share` | Low | An operating plant with no published owner, or co-owners without shares |
| `ownership-over-100` | High | A plant's current owners' shares add up to more than 100% (owners with an `ended_on` date before today aren't counted, so successive owners don't add together) |
| `no-category`, `no-links` | Low | Companies that don't show up anywhere useful |
| state mismatch | High | A unit's state differs from its site's |

## 7. Decisions

### Made

| Decision | By | Where |
|---|---|---|
| One company per brand | Project decision | #23 |
| If we can't source it, we don't publish it | PM | #180 |
| Operators come from NRC, never from EIA's Entity Name | PM, Backend | #227 |
| A state comes from EIA, not NRC's nearest city | Tosin | #197 |
| "Not re-checked" windows: 14 days (NRC, EIA), 365 days (others) | PM | #238 |
| Reactor design types: planned values, roadmap only | Tosin | #238, #263 |
| Display names are ours; a source's spelling never renames | PM, Backend | #241 |
| Company display name is the brand it uses; every other spelling is an alias (D1) | Tosin | #238 |
| Capacity is shown as "MW", noted "Net summer capacity, from EIA" on plant pages (D2) | Tosin | #238 |
| A counted deal is a signed power deal; frameworks and MOUs are listed separately by stage | Tosin | #253, #255 |
| Nuclear Capital Partners is venture capital (#250) | Tosin | #250 |
| Government and research includes independent research organizations (`research_organization`), e.g. EPRI | Tosin | #322, #341 |
| A licensed reactor that produces no power is "Not operating", not "Restarting"; a restart plan is a sourced note | Tosin | #296 |
| 9 company buckets; a company is in every bucket its facts support, with no stored main bucket; tags for detail | Tosin | #266 |
| Scope is the whole nuclear industry, not only power; isotopes are in | Tosin | #266 |
| Bucket names and edge cases ("Waste and decommissioning"; universities in Government and research; fusion and uranium as tags; stable URLs) | Tosin, with Founder and GTM | #266 |
| "Reactor developers" becomes "Developers": reactor designers plus nuclear project developers (`project_developer`), so everything building new nuclear sits together; slug unchanged. A parent never inherits its subsidiaries' buckets | Tosin | #322 |
| A Form D round is recorded on the company itself, never as a link to a placeholder investor; named investors are separate links | PM | #129 |
| A company's SEC CIK identifies it before its name | PM | #129 |
| Plant owners come from EIA-860: Schedule 3's sole owner (code S) at 100%, Schedule 4's owners and shares for J and W; per-unit shares (Catawba), totals off 100 by more than 1, and a new owner on a plant with published owners wait for a person | PM | #382 |
| A short name is a display label only: never an identity key, never matched on | PM | #363 |
| Meta–TerraPower (Jan 2026) is Meta funding TerraPower (`funds`), not a power deal: Meta pays for early development of up to eight Natrium units, and its rights to their energy are in the description. A deal whose main term is money for development is `funds`; a signed purchase of power is `offtake_with` (17 Oct 2026) | Tosin | #393 |
| "Utilities and operators" becomes "Power plant owners and operators" (17 Oct 2026): named for what puts a company there; same rule, slug `utilities` unchanged. The homepage's short label is "Plant operators" | Tosin | #367 |
| Bernhard Capital Partners is an investor (`venture_capital`): it owns Allied Power, a nuclear services company. Reverses #63's "no Bernhard role" (16 Oct 2026) | Tosin | #63, #322 |
| A licensing stage is sourced only from NRC records, never from a press release or news; a stage with no NRC record behind it is never public | Tosin | #379 |
