// Instant search in the browser (#696): the filter for the compact index at /search/index.json.
// Items also carry x: [ids] (NRC docket, ticker, EIA plant id), matched like aliases. payload.tags: [{ s: key, n: name, a: [words], c: companies, i: icon key }] are topic pages.
// Items: { k: "c"|"p", s: slug, n: name, sn: short name, a: [aliases], d: description, m: meta line, i: icon key, b: bucket class, c: connections }.
// prepare() normalises once; search() matches every typed word, ranks exact and prefix names above aliases above
// descriptions, and falls back to close spellings (one letter off, two on long words) only when nothing matches.

export function normalise(text) {
  return String(text || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, " ").trim()
}

// Backend's index is { companies: [{ s, n, sn, a, d, c: category key, m }], plants: [{ s, n, a, t, i: icon name, m }] }; the extras
// ({ icons: { name: svg }, tags }) come from /search/extras.json. Both become items { k, s, n, sn, a, d, x, m, i, b }.
export function prepare(payload) {
  const listed = [
    ...(payload.companies || []).map((c) => ({ ...c, k: "c", i: c.c ? `bucket-${c.c}` : "buildings", b: c.c ? `nd-bucket--${c.c}` : null })),
    ...(payload.plants || []).map((p) => ({ ...p, k: "p" }))
  ]
  const items = listed.map((item) => {
    const names = [item.n, item.sn].filter(Boolean).map(normalise)
    const aliases = [ ...(item.a || []), ...(item.x || []) ].map(normalise).filter(Boolean)
    return { item, names, aliases, name: names[0], nameWords: unique(names.flatMap((n) => n.split(" "))), aliasWords: unique(aliases.flatMap((a) => a.split(" "))), descWords: normalise(item.d).split(" ").filter(Boolean) }
  })
  const tags = (payload.tags || []).map((tag) => ({ tag, names: [tag.n, tag.s, ...(tag.a || [])].map(normalise).filter(Boolean) }))
  return { icons: payload.icons || {}, items, tags }
}

function unique(list) { return [...new Set(list)] }

// Optimal string alignment distance, stopping early once it exceeds `limit`.
export function distance(a, b, limit = 2) {
  if (Math.abs(a.length - b.length) > limit) return limit + 1
  const rows = Array.from({ length: a.length + 1 }, (_, i) => [i])
  for (let j = 1; j <= b.length; j++) rows[0][j] = j
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1
      rows[i][j] = Math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) rows[i][j] = Math.min(rows[i][j], rows[i - 2][j - 2] + 1)
    }
  }
  return rows[a.length][b.length]
}

function exactScore(entry, query, tokens) {
  const { names, aliases } = entry
  if (names.includes(query)) return 100
  if (names.some((n) => n.startsWith(query))) return 90
  if (aliases.includes(query)) return 85
  if (aliases.some((a) => a.startsWith(query))) return 75
  let lowest = Infinity
  for (const token of tokens) {
    let best = 0
    if (entry.nameWords.some((w) => w.startsWith(token))) best = 70
    else if (entry.aliasWords.some((w) => w.startsWith(token))) best = 60
    else if (names.some((n) => n.includes(token))) best = 50
    else if (entry.descWords.some((w) => w.startsWith(token))) best = 30
    if (best === 0) return 0
    lowest = Math.min(lowest, best)
  }
  return lowest
}

function closeScore(entry, tokens) {
  let lowest = Infinity
  for (const token of tokens) {
    let best = 0
    if (entry.nameWords.some((w) => w.startsWith(token)) || entry.aliasWords.some((w) => w.startsWith(token))) best = 40
    else if (token.length >= 4) {
      const limit = token.length >= 8 ? 2 : 1
      const near = (w) => distance(token, w, limit) <= limit || distance(token, w.slice(0, token.length), limit) <= limit
      if (entry.nameWords.some(near) || entry.aliasWords.some(near)) best = 20
    }
    if (best === 0) return 0
    lowest = Math.min(lowest, best)
  }
  return lowest
}

function rank(found) {
  return found.sort((a, b) => b.score - a.score || (b.item.c || 0) - (a.item.c || 0) || a.name.length - b.name.length || a.name.localeCompare(b.name)).map((entry) => entry.item)
}

// Topic pages (HALEU, fusion, SMR, enrichment...) whose name or words the typed text starts, at most two, biggest first.
function topics(index, query) {
  return (index.tags || []).filter(({ names }) => names.some((n) => n === query || n.startsWith(query) || (query.length >= 3 && n.split(" ").some((w) => w === query))))
    .map(({ tag }) => tag).sort((a, b) => (b.c || 0) - (a.c || 0)).slice(0, 2)
}

// => { topics, companies, plants, fuzzy }. fuzzy: nothing matched exactly, these are close names.
export function search(index, text, { companies = 5, plants = 4 } = {}) {
  const query = normalise(text)
  const tokens = query.split(" ").filter(Boolean)
  if (tokens.length === 0) return { topics: [], companies: [], plants: [], fuzzy: false }

  const pick = (score) => {
    const scored = index.items.map((entry) => ({ ...entry, score: score(entry) })).filter((entry) => entry.score > 0)
    return { companies: rank(scored.filter((e) => e.item.k === "c")).slice(0, companies), plants: rank(scored.filter((e) => e.item.k === "p")).slice(0, plants) }
  }

  const matched = topics(index, query)
  const exact = pick((entry) => exactScore(entry, query, tokens))
  if (exact.companies.length || exact.plants.length) return { ...exact, topics: matched, fuzzy: false }
  const close = pick((entry) => closeScore(entry, tokens))
  return { ...close, topics: matched, fuzzy: matched.length === 0 && close.companies.length + close.plants.length > 0 }
}
