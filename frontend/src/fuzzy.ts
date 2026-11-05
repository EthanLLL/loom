/**
 * Fuzzy matching for titles, in the spirit of fzy and telescope: every
 * character of the query must appear in order, and a match scores higher when
 * its characters run together, start a word, or come early. Words in the query
 * are separate terms that must all match, in any order.
 *
 * Only for short labels. Searching what was said is a substring search on the
 * server (`Loom.Search`), where fuzzy matching over long text finds nonsense.
 */
export function fuzzyScore(query: string, text: string): number | null {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return 0
  const hay = text.toLowerCase()
  let total = 0
  for (const term of terms) {
    const score = termScore(term, hay)
    if (score === null) return null
    total += score
  }
  return total
}

function termScore(term: string, hay: string): number | null {
  // A plain substring beats any scattered match.
  const at = hay.indexOf(term)
  if (at !== -1) return 100 + term.length * 10 - at + (boundary(hay, at) ? 20 : 0)

  let score = 0
  let from = 0
  let last = -2
  for (const ch of term) {
    const i = hay.indexOf(ch, from)
    if (i === -1) return null
    score += 1
    if (i === last + 1) score += 5
    if (boundary(hay, i)) score += 3
    score -= Math.min(i - from, 5) * 0.1
    last = i
    from = i + 1
  }
  return score
}

const boundary = (hay: string, i: number) => i === 0 || /[\s/_\-.【[(（]/.test(hay[i - 1])

/** Sessions or anything with a label, best match first; those that do not match are left out. */
export function fuzzyFilter<T>(query: string, items: T[], label: (item: T) => string): T[] {
  return items
    .map((item, index) => ({ item, index, score: fuzzyScore(query, label(item)) }))
    .filter((r): r is { item: T; index: number; score: number } => r.score !== null)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map((r) => r.item)
}
