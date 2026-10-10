# Directory interfaces

`Directory::Lookup` (read) and `Directory::FactWriter` (write) are the **only**
way code outside the directory touches directory data. The data quality
pipeline (`DataQuality::`) and the seed loader both go through them, so there
is one way facts get written. Decision and reasoning: issue #1 (comments),
issue #32.

## Who owns what

| Directory owns | DataQuality owns |
|---|---|
| organizations, organization_aliases, roles, technologies, organization_roles, organization_technologies, facilities, relationships, facility_relationships, evidence | sources, crawl_runs, candidates |

`evidence.source_id` is the one foreign key that crosses the line. Outside the
directory, don't use the directory's models (`Organization`, `Facility`, …)
directly. Call these interfaces instead.

## Directory::Lookup

Returns frozen value objects (`Directory::OrganizationRef`,
`Directory::FacilityRef`), never models, or `nil` when nothing matches. Pass
exactly one keyword.

```ruby
Directory::Lookup.organization(name: "TerraPower, Inc.")   # name or any alias, normalized
Directory::Lookup.organization(domain: "https://www.terrapower.com/news")
Directory::Lookup.organization(slug: "terrapower")
Directory::Lookup.organization(id: 12)

Directory::Lookup.facility(nrc_docket: "05000424")
Directory::Lookup.facility(name: "Plant Vogtle")  # case-insensitive
```

- `OrganizationRef`: `id, slug, name, domain, verification_status`
- `FacilityRef`: `id, slug, name, nrc_docket, parent_id, verification_status`

Every verification status is returned, so check `verification_status` before
treating a match as public.

Names are compared after `OrganizationAlias.normalize`: lowercased, `&` becomes
"and", punctuation removed, trailing Inc / LLC / Co / Corp / Ltd and similar
dropped. "TerraPower, LLC" and "terrapower" match.

## Directory::FactWriter

```ruby
result = Directory::FactWriter.write(kind, attributes, evidence: [...], verification: {...})
result.ok?      # true when written
result.id       # the fact's id
result.created  # true if new, false if an existing fact was updated
result.errors   # array of messages; empty when ok
```

A failed write changes nothing and returns errors. It does not raise.

### Kinds

| kind | attributes | an existing fact is found by |
|---|---|---|
| `organization` | `name slug legal_name website domain description hq_city hq_state country_code founded_year status aliases` | name or any alias (normalized), then domain |
| `organization_role` | `organization_id role` (role **key**) | organization + role |
| `organization_technology` | `organization_id technology` (technology **key**) | organization + technology |
| `facility` | `name slug parent_id facility_type status technology reactor_type capacity_mw nrc_docket city state country_code latitude longitude` | NRC docket, then name |
| `relationship` | `from_organization_id to_organization_id relationship_type description started_on ended_on` | from + to + type |
| `facility_relationship` | `organization_id facility_id relationship_type ownership_pct description started_on ended_on` | organization + facility + type |

Pass `id:` to update a fact you already know. Get ids for other records from
`Directory::Lookup`.

- **Organizations**: the name is stored as an alias as well, along with
  `aliases:`. An alias already used by another organization is an error.
  `domain` defaults to the website's; pass `domain: nil` to leave it blank,
  for example when several organizations share one website.
- **Relationship types**: `supplies`, `invests_in` (equity), `funds` (grants
  and awards), `offtake_with`, `subsidiary_of` (child → parent).
- **Facility link types**: `owns`, `operates`, `vendor_for`, `offtakes_from`.

### Evidence

Each item: `source_id` (required), `quote`, `found_by` (`crawler`, `verifier`
or `human`), `confidence` (0–1), `crawl_run_id`. Evidence is matched by source
and quote, so writing the same item again updates it and never duplicates it.

### Verification

`verification: { status: "verified", by: "human:tosin" }`. Status is
`pending`, `verified` or `rejected`. `by` names who decided: `human:<name>` or
`agent:verifier/<model>`. Re-applying the same decision keeps the original
`verified_at`. Only verified facts are public.

### Confidence

Recomputed after every write, by one rule in `Evidence.combined_confidence`:
a fact a human has verified scores 1. Otherwise it scores the strongest piece
of evidence, plus 0.1 when sources on two or more domains agree, capped at 1.
