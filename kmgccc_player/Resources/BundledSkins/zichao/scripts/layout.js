// 字潮: line layout
//
// layoutLine(words, options) composes one lyric line as poster typography and returns where
// every word goes. Units: 100 is one em of ordinary text; the scene multiplies by its own unit.
//
// The line is cut into segments (a word, or a CJK word found by the system tokenizer). The
// segment with the most text and time is the hero; segments held longer than the line's pace,
// or picked at random on longer lines, become semi-heroes. A composition is then generated from
// seeded choices: an archetype (rows, a hero on its own row, a vertical hero opening, closing or
// standing between the rows, vertical columns, a cascade, an arc, a wave, a justified block,
// slanted rows, stepped vertical columns, plain calm rows for slow lines), then its row breaks,
// alignment, stairs, vertical alignment, spacing, size contrast, tilt, and where and how each
// word enters. Every composition reads in the order the line is sung: rows top to bottom and
// left to right, columns top to bottom. Boxes too close are pushed apart only along that order
// (a later word moves on along its row or to the next one), and the whole is scaled to the
// safe area.
//
// words: lyric words ({text, start, end}) or plain texts. A single word holding a whole line (a
// line without word timing) is first spread over its tokens, so `items` may outnumber `words`.
// options:
//   seed        any number; the same seed gives the same composition
//   avoid       families of recent lines, so a composition is not repeated
//   width       safe area, in layout units
//   height
//   advance     vertical glyph pitch in em
//   font        one name, or [latin, cjk]
//   weight
//   energy      hero size, 1 is designed
//   complexity  0 simple: rows read left to right with an occasional vertical word; 1 rich:
//               every archetype; values between mix them
//
// Result:
//   family      archetype × 1000 + variant
//   archetype
//   hero        item index of the hero's first word
//   heroBox     [x, y, w, h] of the whole hero segment
//   heroTime    [start, end] of the whole hero segment
//   size        [w, h]
//   ghost       [x, y, scale]; scale 0 for none
//   ghostText
//   items       one per word:
//     x, y      centre
//     s         scale
//     w, h      box
//     v         1 for a stacked vertical word
//     r         degrees
//     ex, ey    unit direction it comes from
//     m         how it enters: 0 slide, 1 zoom, 2 spin, 3 zip, 4 fall
//     role      0 support, 1 semi-hero, 2 hero
//     k         1 for CJK
//     seg       segment number
//     t         text to draw
//     start, end

var KineticLayout = (function () {
  'use strict'

  // Archetype numbers are part of `family`; keep them stable.
  const ROWS = 0, HERO_ROW = 1, SIDE = 2, PILLAR = 3, ORBIT = 4, COLUMNS = 5, CASCADE = 6, ARC = 7
  const SINGLE = 8, WAVE = 9, BLOCK = 10, SCATTER = 11, SPIRAL = 12, SLANT = 13, STEPS = 14, CALM = 15
  const ARCHETYPE_COUNT = 16

  const WHITESPACE = /\s/u
  const PUNCTUATION = /\p{P}/u
  const SYMBOL = /\p{S}/u
  const LETTER = /\p{Alphabetic}/u
  const CJK = /[⺀-鿿가-힯豈-﫿぀-ヿ]/u

  const isCJK = (c) => CJK.test(c)
  const hasCJK = (text) => CJK.test(text)
  const chars = (text) => Array.from(text)
  const sum = (values) => values.reduce((a, b) => a + b, 0)
  const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x))
  const roundAway = (x) => Math.sign(x) * Math.round(Math.abs(x))
  const range = (lo, hi) => { const out = []; for (let i = lo; i < hi; i++) out.push(i); return out }
  const text = (v) => (v == null ? '' : String(v))
  const num = (v, fallback) => {
    if (typeof v === 'number') return isFinite(v) ? v : fallback
    if (typeof v === 'boolean') return v ? 1 : 0
    if (typeof v === 'string' && v.trim() !== '' && isFinite(Number(v))) return Number(v)
    return fallback
  }

  /** Seeded draws: each call returns the next value in 0..<1. */
  class Draws {
    constructor(seed) { this.seed = seed; this.count = 0 }
    next() {
      this.count += 1
      const value = Math.sin(this.seed * 91.3458 + this.count * 47.123 + 0.5) * 43758.5453
      return value - Math.floor(value)
    }
    chance(p) { return this.next() < p }
    range(lo, hi) { return lo + (hi - lo) * this.next() }
    pick(weights) {
      const total = sum(weights)
      if (!(total > 0)) return 0
      let value = this.next() * total
      for (let i = 0; i < weights.length; i++) {
        value -= weights[i]
        if (value <= 0 && weights[i] > 0) return i
      }
      for (let i = weights.length - 1; i >= 0; i--) if (weights[i] > 0) return i
      return 0
    }
  }

  function line(words, options) {
    words = words.slice(0, 64)
    if (!words.length) return { items: [], family: -1, archetype: -1, hero: -1, size: [0, 0] }
    const seed = num(options.seed, 0)
    const avoid = new Set((options.avoid || []).map((v) => Math.trunc(num(v, -1))))
    const safeW = Math.max(200, num(options.width, 1400))
    const safeH = Math.max(150, num(options.height, 800))
    const fonts = Array.isArray(options.font) ? options.font.map(text) : [text(options.font)]
    const latinFont = fonts[0] || '', cjkFont = fonts.length > 1 ? fonts[1] : latinFont
    const weight = text(options.weight) || 'heavy'
    // A vertical word is drawn one line per character, so each takes at least the font's own
    // line height; a smaller advance would make the column taller than its box.
    const advance = Math.max(0.8, num(options.advance, 1.08), host.lineHeight(cjkFont, weight, 100) / 100)
    const energy = clamp(num(options.energy, 1), 0, 3)
    const complexity = options.complexity == null ? 1 : clamp(num(options.complexity, 1), 0, 1)
    const draws = new Draws(seed)

    // Words and their inked widths at size 100, trailing spaces excluded.
    const isRecord = (w) => w != null && typeof w === 'object' && !Array.isArray(w)
    let texts = words.map((w) => (isRecord(w) ? text(w.text) : text(w)))
    let starts = words.map((w) => (isRecord(w) ? num(w.start, 0) : 0))
    let ends = words.map((w, i) => Math.max(starts[i], isRecord(w) ? num(w.end, starts[i]) : starts[i]))
    // A line without word timing arrives as one word; spread it over its tokens by length.
    if (texts.length === 1) {
      const tokens = spread(texts[0])
      if (tokens.length > 1) {
        const weights = tokens.map((t) => Math.max(1, chars(t).filter((c) => !WHITESPACE.test(c)).length))
        const total = sum(weights), span = ends[0] - starts[0], begin = starts[0]
        let offset = 0
        texts = tokens; starts = []; ends = []
        for (const w of weights) {
          starts.push(begin + span * offset / total)
          offset += w
          ends.push(begin + span * offset / total)
        }
      }
    }
    const inked = texts.map((t) => t.trim())
    const widths = inked.map((t) => host.measureText(t, 100, weight, hasCJK(t) ? cjkFont : latinFont))

    const parts = segment(texts, inked, widths, starts, ends)
    const n = parts.length
    const totalChars = Math.max(1, sum(parts.map((p) => p.chars)))
    const cjkChars = sum(parts.map((p) => (p.cjk ? p.chars : 0)))
    const cjkLine = cjkChars * 2 >= totalChars
    const lineSpan = Math.max(0.1, Math.max(...ends) - Math.min(...starts))

    // Roles: the hero, then semi-heroes held longer than the line's pace or picked at random.
    const score = (p) => Math.min(p.chars, 8) * 14 + Math.min(2.5, p.duration) * 18
    let hero = -1
    parts.forEach((p, i) => { if (p.wordLike && (hero < 0 || score(p) > score(parts[hero]))) hero = i })
    if (hero < 0) hero = 0
    parts[hero].role = 2
    const perChar = lineSpan / totalChars
    const semiLimit = n < 3 ? 0 : (n <= 5 ? 1 : (n <= 10 ? 2 : 3))
    const held = (p) => p.duration >= 0.45 && p.duration / Math.max(1, p.chars) >= perChar * 1.8
    const candidates = range(0, n).filter((i) => i !== hero && parts[i].wordLike && Math.abs(i - hero) >= (n <= 4 ? 1 : 2)
      && (score(parts[i]) >= score(parts[hero]) * 0.35 || held(parts[i])))
    const jitter = parts.map(() => draws.next() * 24)
    const rank = (i) => score(parts[i]) + (held(parts[i]) ? 40 : 0) + jitter[i]
    candidates.sort((a, b) => rank(b) - rank(a))
    const semis = []
    for (const i of candidates) {
      if (semis.length < semiLimit && semis.every((s) => Math.abs(s - i) >= 2)) semis.push(i)
    }
    const spare = range(0, n).filter((i) => i !== hero && parts[i].wordLike && Math.abs(i - hero) >= 2)
    if (!semis.length && n >= 3 && draws.chance(0.4) && spare.length) {
      semis.push(spare[Math.min(spare.length - 1, Math.floor(draws.next() * spare.length))])
    }
    for (const i of semis) parts[i].role = 1

    // Archetype. Specials are never repeated within two lines; rows only grow less likely.
    const gap = cjkLine ? 20 : 32
    const plainWidth = sum(parts.map((p) => p.width)) + gap * Math.max(0, n - 1)
    const wide = plainWidth / safeW
    const c = complexity
    const heroCJK = parts[hero].cjk && parts[hero].chars >= 2 && parts[hero].chars <= 8
    const avoided = new Set(Array.from(avoid, (v) => (v >= 0 ? Math.trunc(v / 1000) : -1)))
    const weights = new Array(ARCHETYPE_COUNT).fill(0)
    const between = (x, lo, hi) => x >= lo && x <= hi
    if (n === 1) {
      weights[SINGLE] = 1
    } else {
      // Only compositions that read in the order the line is sung: an orbit, a spiral or a
      // collage puts words around the hero, so the eye jumps back and forth; they are kept
      // for `avoid` families but never drawn.
      weights[ROWS] = 3
      weights[HERO_ROW] = 2.6
      // A vertical hero beside the rows opens or closes the line, never interrupts it.
      weights[SIDE] = hero === 0 || hero === n - 1
        ? (heroCJK ? 0.3 + 0.8 * c : (parts[hero].chars >= 3 && !parts[hero].cjk ? 0.4 * c : 0)) : 0
      weights[PILLAR] = heroCJK && hero > 0 && hero < n - 1 ? 0.8 * c : 0
      weights[COLUMNS] = cjkLine && totalChars <= 22 ? 0.9 * c : 0
      weights[CASCADE] = between(n, 2, 6) ? 0.15 + 0.6 * c : 0
      weights[ARC] = between(n, 3, 9) && wide < 2.4 ? 0.5 * c : 0
      weights[WAVE] = between(n, 3, 10) && wide < 3 ? 0.4 * c : 0
      weights[BLOCK] = between(n, 2, 8) ? 0.6 + 0.8 * c : 0
      weights[SLANT] = 0.5 * c
      weights[STEPS] = cjkLine && between(n, 2, 7) && totalChars <= 18 ? 0.7 * c : 0
      // Slow singing (long per character) reads as a quiet line.
      const slow = clamp((perChar - (cjkLine ? 0.28 : 0.18)) / 0.25, 0, 1)
      weights[CALM] = 0.35 + 1.6 * slow
      for (let a = 0; a < ARCHETYPE_COUNT; a++) {
        if (!avoided.has(a)) continue
        if (a === CALM) weights[a] *= 2.2
        else if (a === ROWS || a === HERO_ROW || a === BLOCK) weights[a] *= 0.45
        else weights[a] = 0
      }
      if (weights.every((w) => w <= 0)) weights[ROWS] = 1
    }
    const archetype = draws.pick(weights)

    // Size contrast. Rich lines reach further in both directions.
    let growth
    switch (archetype) {
      case ROWS: case SLANT: growth = [0.9 + 0.2 * c, 1.5 + 0.4 * c]; break
      case HERO_ROW: growth = [1.4, 2.0 + 0.4 * c]; break
      case SIDE: case PILLAR: growth = [1.6, 2.2]; break
      case ORBIT: case SPIRAL: growth = [1.4, 2.0]; break
      case COLUMNS: case STEPS: growth = [0.9, 1.5]; break
      case CASCADE: case ARC: case WAVE: growth = [0.9, 1.5]; break
      case SINGLE: growth = [1.6, 2.1]; break
      case BLOCK: growth = [0.4, 0.9]; break
      case SCATTER: growth = [1.2, 2.0 + 0.4 * c]; break
      default: growth = [0.08, 0.25] // calm
    }
    // A long Latin hero grows less: a word is far wider than a CJK character of the same size.
    const heroDamp = parts[hero].cjk ? 1 : (parts[hero].chars > 7 ? 0.55 : (parts[hero].chars > 4 ? 0.75 : 0.9))
    const heroScale = 1 + draws.range(growth[0], growth[1]) * energy * heroDamp
    const semiScale = 1 + (heroScale - 1) * draws.range(0.3, 0.5)
    // Supports: flat, a little uneven, swelling toward the hero, alternating, or tapering.
    const scheme = archetype === CALM ? 0 : draws.pick([1, 1 + c, 0.8 * c, 0.6 * c, 0.6 * c])
    const kicker = archetype === HERO_ROW && hero > 0 && draws.chance(0.5)
    parts.forEach((part, i) => {
      if (part.role === 2) part.scale = heroScale
      else if (part.role === 1) part.scale = semiScale
      else {
        let s = 1
        switch (scheme) {
          case 1: s = 1 + (draws.next() - 0.5) * (0.1 + 0.16 * c); break
          case 2: s = 0.86 + 0.28 * (1 - Math.min(1, Math.abs(i - hero) / 4)); break
          case 3: s = i % 2 === 0 ? 1 : 0.82; break
          case 4: s = 1.1 - 0.25 * i / Math.max(1, n - 1); break
        }
        // A collage mixes sizes freely.
        if (archetype === SCATTER) s *= draws.range(0.7, 1.5)
        if (kicker && i < hero) s *= 0.78
        part.scale = s
      }
      // Latin sits a little smaller than CJK at the same size.
      if (!part.cjk) part.scale *= 0.8
    })

    // Orientation, then box sizes. Rows keep every word upright; a vertical word stands only
    // where the composition is built around it.
    const verticalHero = archetype === SIDE || archetype === PILLAR
      || (archetype === SINGLE && heroCJK && draws.chance(0.12 + 0.25 * c))
    parts.forEach((part, i) => {
      let stacked = archetype === COLUMNS || (archetype === STEPS && part.chars > 1)
      if (i === hero && verticalHero) stacked = true
      if (stacked) {
        if (part.cjk) part.vertical = true
        else if (part.chars > 1 && archetype !== COLUMNS) part.rotated = true
      }
      const s = part.scale
      if (part.vertical) { part.w = 100 * s; part.h = Math.max(1, part.chars) * advance * 100 * s }
      else if (part.rotated) { part.w = 102 * s; part.h = part.width * s }
      else { part.w = part.width * s; part.h = 102 * s }
    })

    const variant = compose(parts, archetype, hero, gap, safeW, safeH, c, avoid, draws)

    // Fit the whole composition (tilted boxes counted by their rotated extent) and centre it.
    const minX = Math.min(...parts.map((p) => p.x - extent(p).w / 2)), maxX = Math.max(...parts.map((p) => p.x + extent(p).w / 2))
    const minY = Math.min(...parts.map((p) => p.y - extent(p).h / 2)), maxY = Math.max(...parts.map((p) => p.y + extent(p).h / 2))
    const fit = Math.max(0.45, Math.min(1, safeW / Math.max(1, maxX - minX), safeH / Math.max(1, maxY - minY)))
    const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    for (const p of parts) {
      p.x = (p.x - cx) * fit; p.y = (p.y - cy) * fit
      p.scale *= fit; p.w *= fit; p.h *= fit
    }

    // Words inside their segments, laid along the segment's own axis and tilt.
    const items = []
    parts.forEach((part, number) => {
      const along = part.vertical || part.rotated
      let cursor = along ? -part.h / 2 : -part.w / 2
      const angle = part.tilt * Math.PI / 180
      for (let index = part.first; index <= part.last; index++) {
        const s = part.scale
        const word = inked[index]
        let dx = 0, dy = 0, w = widths[index] * s, h = 102 * s, shown = word
        if (part.vertical) {
          const glyphs = chars(word).filter((ch) => !WHITESPACE.test(ch))
          // A space takes no room in a column: it sits where the previous glyph ends.
          h = glyphs.length * advance * 100 * s
          w = 100 * s
          dy = cursor + h / 2
          cursor += h
          shown = glyphs.join('\n')
        } else if (part.rotated) {
          dy = cursor + w / 2
          cursor += w
          const t = w; w = h; h = t
        } else {
          dx = cursor + w / 2
          cursor += w
        }
        items.push({
          x: part.x + dx * Math.cos(angle) - dy * Math.sin(angle),
          y: part.y + dx * Math.sin(angle) + dy * Math.cos(angle),
          s, w, h, v: part.vertical ? 1 : 0, r: (part.rotated ? 90 : 0) + part.tilt,
          ex: part.ex, ey: part.ey, m: part.mode, role: part.role, k: part.cjk ? 1 : 0, seg: number,
          t: shown, start: starts[index], end: ends[index],
        })
      }
    })

    const ghostArchetypes = [ROWS, HERO_ROW, SIDE, PILLAR, ORBIT, CASCADE, SPIRAL, SLANT, STEPS]
    const h = parts[hero]
    const hasGhost = ghostArchetypes.includes(archetype) && h.chars <= 6 && draws.chance(0.6)
    const ghostScale = hasGhost ? Math.min(5, Math.max(2.6, h.scale * 1.7)) : 0
    const ghostSide = draws.chance(0.5) ? -1 : 1
    return {
      family: archetype * 1000 + variant, archetype,
      hero: h.first,
      heroBox: [h.x, h.y, h.w, h.h],
      heroTime: [h.start, h.end],
      size: [(maxX - minX) * fit, (maxY - minY) * fit],
      ghost: [h.x - safeW * 0.1 * ghostSide, h.y - safeH * 0.06, ghostScale], ghostText: h.text,
      items,
    }
  }

  // MARK: Segments

  /** CJK per character, other text per word with its trailing space; punctuation stays attached. */
  function spread(source) {
    const tokens = []
    let current = '', inWord = false
    for (const ch of chars(source)) {
      if (WHITESPACE.test(ch)) {
        if (current) current += ch
        inWord = false
      } else if (PUNCTUATION.test(ch) && current) {
        current += ch
      } else if (inWord && !isCJK(ch)) {
        current += ch
      } else {
        if (current) tokens.push(current)
        current = ch
        inWord = !isCJK(ch)
      }
    }
    if (current) tokens.push(current)
    return tokens.slice(0, 64)
  }

  function segment(texts, inked, widths, starts, ends) {
    // Word starts from the system tokenizer, in UTF-16 offsets like `offset` below.
    const tokenStarts = new Set(host.wordStarts(texts.join('')))
    const result = []
    let offset = 0
    texts.forEach((source, index) => {
      const ink = inked[index]
      const glyphs = chars(ink)
      const cjk = hasCJK(ink)
      const punctuation = glyphs.length > 0 && glyphs.every((ch) => PUNCTUATION.test(ch) || SYMBOL.test(ch))
      const count = glyphs.filter((ch) => !WHITESPACE.test(ch) && !PUNCTUATION.test(ch)).length
      const last = result[result.length - 1]
      let begins = true
      if (last && index > 0) {
        const before = chars(texts[index - 1]), after = chars(source)
        const spaced = (before.length > 0 && WHITESPACE.test(before[before.length - 1])) || (after.length > 0 && WHITESPACE.test(after[0]))
        if (punctuation || !ink) begins = false
        else if (spaced) begins = true
        else if (cjk && last.cjk) begins = tokenStarts.has(offset) || last.chars >= 4
        else begins = cjk !== last.cjk
      }
      offset += source.length
      if (begins) {
        result.push({
          first: index, last: index, text: ink, width: widths[index], chars: count,
          start: starts[index], end: ends[index], cjk, wordLike: LETTER.test(ink),
          role: 0, scale: 1, vertical: false, rotated: false, x: 0, y: 0, w: 0, h: 0,
          ex: 0, ey: 1, mode: 0, tilt: 0,
          get duration() { return Math.max(0, this.end - this.start) },
        })
      } else {
        last.last = index
        last.text += ink
        last.width += widths[index]
        last.chars += count
        // A space is never sung; its time is the pause after the word, not part of it.
        if (ink) last.end = Math.max(last.end, ends[index])
        last.wordLike = last.wordLike || LETTER.test(ink)
      }
    })
    return result
  }

  // MARK: Composition

  /** The box a part covers once turned by its tilt. */
  function extent(p) {
    const angle = Math.abs(p.tilt) * Math.PI / 180
    return { w: p.w * Math.cos(angle) + p.h * Math.sin(angle), h: p.h * Math.cos(angle) + p.w * Math.sin(angle) }
  }

  /**
   * Places every segment for `archetype` and sets where each enters from. Returns the variant
   * number (0…999) that, with the archetype, names the composition for `avoid`.
   */
  function compose(parts, archetype, hero, baseGap, safeW, safeH, c, avoid, draws) {
    const n = parts.length
    const all = range(0, n)
    const before = range(0, hero), after = range(hero + 1, n)
    const gap = baseGap * draws.range(0.95, 1.2 + 0.5 * c)
    // Rows stand at least a word gap apart, the least room the final check allows anywhere.
    const leading = Math.max(gap + 1, 36 * draws.range(0.55, 0.85 + 0.5 * c))

    // Row style: alignment 0 left, 1 centre, 2 right, 3 justified; vertical alignment 0
    // bottom, 1 centre, 2 top; stairs offset each row a little further along.
    let align = 0, valign = 0, stairs = 0, pattern = 0, extraRows = 0, signature = 0
    for (let attempt = 0; attempt < 4; attempt++) {
      align = draws.pick([1.2, 1.4, 0.4 + 0.6 * c, 0.5 + 0.5 * c])
      valign = draws.pick([1.6, 0.8, 0.3 + 0.5 * c])
      stairs = draws.chance(0.1 + 0.2 * c) ? (draws.chance(0.7 - 0.3 * c) ? 1 : -1) * safeW * draws.range(0.03, 0.05 + 0.04 * c) : 0
      pattern = draws.pick([1.5, 0.8 + 0.4 * c, 0.6 + 0.4 * c, 0.4 * c])
      extraRows = draws.pick([1.4, 1, 0.6 * c])
      signature = align + 4 * valign + 16 * (stairs > 0 ? 1 : (stairs < 0 ? 2 : 0)) + 96 * pattern + 384 * extraRows
      if (!avoid.has(archetype * 1000 + signature)) break
    }

    /**
     * Splits `indices` into `count` rows by width, the rows' shares following `pattern`
     * (even, growing, shrinking, uneven). Every row keeps at least one segment.
     */
    function breakRows(indices, count) {
      count = Math.max(1, Math.min(indices.length, count))
      if (count <= 1) return [indices]
      let shares = range(0, count).map((row) => {
        switch (pattern) {
          case 1: return 1 + row * 0.6
          case 2: return 1 + (count - 1 - row) * 0.6
          case 3: return 0.6 + draws.next()
          default: return 1
        }
      })
      const total = sum(shares)
      shares = shares.map((s) => s / total)
      const widths = indices.map((i) => parts[i].w)
      const width = sum(widths) + gap * (indices.length - 1)
      const rows = [[]]
      let used = 0, boundary = shares[0] * width
      indices.forEach((index, position) => {
        const remainingItems = indices.length - position
        const remainingRows = count - rows.length
        const middle = used + widths[position] / 2
        if (rows[rows.length - 1].length && remainingRows > 0 && (middle > boundary || remainingItems <= remainingRows)) {
          rows.push([])
          boundary += shares[rows.length - 1] * width
        }
        rows[rows.length - 1].push(index)
        used += widths[position] + gap
      })
      return rows
    }

    function rowCount(indices, measure) {
      if (!indices.length) return 0
      const width = sum(indices.map((i) => parts[i].w)) + gap * (indices.length - 1)
      const least = Math.max(1, Math.ceil(width / measure))
      return Math.min(indices.length, least + extraRows)
    }

    /** Lays `rows` top to bottom from `top`, each row left to right. Returns the block's bottom. */
    function layRows(rows, left, top, rowAlign) {
      const rowWidths = rows.map((row) => sum(row.map((i) => parts[i].w)) + gap * Math.max(0, row.length - 1))
      const block = rowWidths.length ? Math.max(...rowWidths) : 0
      let y = top
      rows.forEach((row, number) => {
        if (!row.length) return
        const height = Math.max(...row.map((i) => parts[i].h))
        let spacing = gap
        let x = left
        switch (rowAlign) {
          case 1: x += (block - rowWidths[number]) / 2; break
          case 2: x += block - rowWidths[number]; break
          case 3:
            if (row.length > 1) spacing = gap + (block - rowWidths[number]) / (row.length - 1)
            else x += (block - rowWidths[number]) / 2
            break
        }
        x += number * stairs
        for (const i of row) {
          const p = parts[i]
          p.x = x + p.w / 2
          if (valign === 1) p.y = y + height / 2
          else if (valign === 2) p.y = y + p.h / 2
          else p.y = y + height - p.h / 2
          x += p.w + spacing
        }
        y += height + leading
      })
      return y - leading
    }

    const maxOf = (indices, f, fallback) => (indices.length ? Math.max(...indices.map(f)) : fallback)
    const minOf = (indices, f, fallback) => (indices.length ? Math.min(...indices.map(f)) : fallback)
    const measure = safeW * draws.range(0.55, 0.95)
    switch (archetype) {
      case CALM: {
        // Even rows broken by width alone: no stairs or extra rows.
        stairs = 0; valign = 1; pattern = 0; extraRows = 0
        align = draws.chance(0.6) ? 1 : 0
        signature = align
        layRows(breakRows(all, rowCount(all, safeW * 0.72)), 0, 0, align)
        break
      }
      case ROWS: case ORBIT: case SCATTER: case SPIRAL:
        // An orbit, a collage and a spiral are never chosen (see the weights); they stay as
        // archetype numbers so families from older lines still compare.
        layRows(breakRows(all, rowCount(all, measure)), 0, 0, align)
        break
      case HERO_ROW: {
        let y = 0
        if (before.length) y = layRows(breakRows(before, rowCount(before, measure)), 0, 0, align) + leading * 1.3
        layRows([[hero]], 0, y, align)
        const h = parts[hero]
        y = h.y + h.h / 2 + leading * 1.3
        if (after.length) layRows(breakRows(after, rowCount(after, measure)), 0, y, align)
        // Rows share one left edge or centre line with the hero row.
        const anchor = align === 2 ? h.x + h.w / 2 : (align === 0 ? h.x - h.w / 2 : h.x)
        for (const group of [before, after]) {
          if (!group.length) continue
          const lo = minOf(group, (i) => parts[i].x - parts[i].w / 2, 0), hi = maxOf(group, (i) => parts[i].x + parts[i].w / 2, 0)
          const edge = align === 2 ? hi : (align === 0 ? lo : (lo + hi) / 2)
          for (const i of group) parts[i].x += anchor - edge
        }
        break
      }
      case SIDE: case PILLAR: {
        const heroBox = { w: parts[hero].w, h: parts[hero].h }
        const rowHeight = maxOf(all.filter((i) => parts[i].role !== 2), (i) => parts[i].h, 102) + leading
        const others = before.concat(after)
        const lines = Math.max(1, Math.min(others.length, roundAway(heroBox.h / rowHeight)))
        if (archetype === SIDE) {
          // The vertical hero stands on the side its place in the line suggests.
          const heroLeft = hero <= Math.trunc((n - 1) / 2)
          const rows = breakRows(others, lines)
          const bottom = layRows(rows, 0, 0, heroLeft ? 0 : 2)
          const blockW = maxOf(others, (i) => parts[i].x + parts[i].w / 2, 0)
          const place = draws.pick([1, 1, 0.8])
          const dy = place === 0 ? -heroBox.h / 2 : (place === 1 ? -bottom / 2 : heroBox.h / 2 - bottom)
          for (const i of others) {
            parts[i].x += heroLeft ? heroBox.w / 2 + gap * 1.5 : -(blockW + heroBox.w / 2 + gap * 1.5)
            parts[i].y += dy
          }
        } else {
          const leftRows = breakRows(before, Math.max(1, Math.trunc(lines / 2)))
          const rightRows = breakRows(after, Math.max(1, Math.trunc(lines / 2)))
          const leftBottom = layRows(leftRows, 0, 0, 2)
          const leftW = maxOf(before, (i) => parts[i].x + parts[i].w / 2, 0)
          for (const i of before) { parts[i].x += -leftW - heroBox.w / 2 - gap * 1.5; parts[i].y += -heroBox.h / 2 }
          const rightBottom = layRows(rightRows, 0, 0, 0)
          const diagonal = draws.chance(0.6)
          for (const i of after) {
            parts[i].x += heroBox.w / 2 + gap * 1.5
            parts[i].y += diagonal ? heroBox.h / 2 - rightBottom : -heroBox.h / 2 + Math.max(0, leftBottom - rightBottom) / 2
          }
        }
        parts[hero].x = 0; parts[hero].y = 0
        break
      }
      case COLUMNS: {
        // Top to bottom, columns from right to left.
        const cap = Math.max(parts[hero].h, safeH * draws.range(0.6, 0.9))
        const drop = draws.chance(0.5) ? draws.range(20, 60) : 0
        let x = 0, y = 0, columnWidth = 0, column = 0
        for (const i of all) {
          const p = parts[i]
          if (y > 0 && y + p.h > cap) { x -= columnWidth + gap * 1.6; y = 0; columnWidth = 0; column += 1 }
          p.x = x - p.w / 2
          p.y = column * drop + y + p.h / 2
          y += p.h + 11
          columnWidth = Math.max(columnWidth, p.w)
        }
        break
      }
      case CASCADE: {
        let y = 0
        const step = draws.range(0.35, 0.65) * (sum(parts.map((p) => p.w)) / n)
        for (const i of all) {
          parts[i].x = i * step + parts[i].w / 2
          parts[i].y = y + parts[i].h / 2
          y += parts[i].h + leading * 0.4
        }
        break
      }
      case ARC: {
        const spacing = gap * 1.3
        const length = sum(parts.map((p) => p.w)) + spacing * (n - 1)
        const sweep = draws.range(0.55, 0.9 + 0.3 * c)
        const radius = length / sweep
        const arch = draws.chance(0.55) ? 1 : -1
        let cursor = -length / 2
        for (const p of parts) {
          const phi = (cursor + p.w / 2) / radius
          p.x = radius * Math.sin(phi)
          p.y = arch * radius * (1 - Math.cos(phi))
          p.tilt = arch * phi * 180 / Math.PI
          cursor += p.w + spacing
        }
        break
      }
      case SINGLE:
        parts[hero].x = 0; parts[hero].y = 0
        if (!parts[hero].vertical && draws.chance(0.35 * c)) parts[hero].tilt = (draws.next() - 0.5) * 10
        break
      case WAVE: {
        // A sine baseline whose steepest slope stays under 0.35, each word turned to it.
        const tallest = maxOf(all, (i) => parts[i].h, 102)
        let spacing = gap * 1.3 + 0.12 * tallest
        const turns = draws.range(0.6, 1.3), share = draws.range(0.5, 1)
        const phase = draws.range(0, 2 * Math.PI)
        // Neighbours turned to different slopes can touch at a corner; open the spacing until none do.
        for (let attempt = 0; attempt < 8; attempt++) {
          const length = sum(parts.map((p) => p.w)) + spacing * (n - 1)
          const k = 2 * Math.PI * turns / Math.max(1, length)
          const amplitude = 0.35 / k * share
          let cursor = -length / 2
          for (const p of parts) {
            const x = cursor + p.w / 2
            p.x = x
            p.y = amplitude * Math.sin(k * x + phase)
            p.tilt = Math.atan(amplitude * k * Math.cos(k * x + phase)) * 180 / Math.PI
            cursor += p.w + spacing
          }
          if (!all.slice(1).some((i) => overlaps(parts[i - 1], parts[i], 6))) break
          spacing *= 1.35
        }
        break
      }
      case BLOCK: {
        // Rows scaled up or down to one width, so the line reads as a justified block.
        const count = Math.max(2, Math.min(Math.min(n, 5), roundAway(n / draws.range(1.2, 2.4))))
        const rows = breakRows(all, count)
        const natural = rows.map((row) => sum(row.map((i) => parts[i].w)))
        const target = (natural.length ? Math.max(...natural) : 1) * draws.range(0.85, 1.1)
        rows.forEach((row, number) => {
          const room = target - gap * Math.max(0, row.length - 1)
          const factor = Math.min(3.2, Math.max(0.55, room / Math.max(1, natural[number])))
          for (const i of row) { parts[i].scale *= factor; parts[i].w *= factor; parts[i].h *= factor }
        })
        layRows(rows, 0, 0, draws.chance(0.7) ? 3 : 1)
        break
      }
      case SLANT:
        layRows(breakRows(all, rowCount(all, measure)), 0, 0, align)
        break
      case STEPS: {
        // Vertical columns left to right, each starting a step lower (or higher) than the last.
        const step = (sum(parts.map((p) => p.h)) / n) * draws.range(0.18, 0.4) * (draws.chance(0.75) ? 1 : -1)
        let x = 0
        all.forEach((i, order) => {
          parts[i].x = x + parts[i].w / 2
          parts[i].y = order * step + parts[i].h / 2
          x += parts[i].w + gap * 1.6
        })
        break
      }
    }

    separate(parts, archetype, hero, gap)

    // A slight tilt of the whole composition on rich lines; a slant turns it clearly. Turning
    // the whole keeps every gap, so it comes after the separation.
    const slant = archetype === SLANT
    if (slant || ([ROWS, HERO_ROW, CASCADE, BLOCK].includes(archetype) && draws.chance(0.12 * c))) {
      const angle = (slant ? (draws.chance(0.5) ? 1 : -1) * draws.range(5, 11) : (draws.next() - 0.5) * 5) * Math.PI / 180
      for (const p of parts) {
        const x = p.x, y = p.y
        p.x = x * Math.cos(angle) - y * Math.sin(angle)
        p.y = x * Math.sin(angle) + y * Math.cos(angle)
        p.tilt += angle * 180 / Math.PI
      }
    }

    enter(parts, archetype, hero, align, c, draws)
    return signature
  }

  /**
   * Keeps every two boxes, each turned by its tilt, at least one word gap apart without breaking
   * the order the line is sung in. A later word that comes too close to an earlier one only moves
   * on: right along its row or down to the next row; in vertical columns, down its column or on
   * to the next column. Of the two, the shorter move is taken. The hero stays put and moves an
   * earlier word back the same ways instead.
   */
  function separate(parts, archetype, hero, gap) {
    // Columns read right to left, stepped columns left to right, everything else in rows.
    const side = archetype === COLUMNS ? -1 : 1
    for (let pass = 0; pass < 40; pass++) {
      let moved = false
      for (let i = 0; i < parts.length; i++) {
        for (let j = i + 1; j < parts.length; j++) {
          if (!overlaps(parts[i], parts[j], gap)) continue
          const a = extent(parts[i]), b = extent(parts[j])
          // How far `j` must go down, or across (in the reading direction), to clear `i`.
          const down = parts[i].y + a.h / 2 + gap - (parts[j].y - b.h / 2)
          const across = side > 0
            ? parts[i].x + a.w / 2 + gap - (parts[j].x - b.w / 2)
            : parts[j].x + b.w / 2 + gap - (parts[i].x - a.w / 2)
          let dx = 0, dy = 0
          if (across > 0 && (across < down || down <= 0)) dx = side * (across + 0.5)
          else dy = Math.max(0, down) + 0.5
          if (j === hero) { parts[i].x -= dx; parts[i].y -= dy }
          else { parts[j].x += dx; parts[j].y += dy }
          moved = true
        }
      }
      if (!moved) break
    }
  }

  /** Whether two boxes, each turned by its tilt, come within `margin` of each other. */
  function overlaps(a, b, margin) {
    const corners = (p) => {
      const angle = p.tilt * Math.PI / 180, hw = p.w / 2 + margin / 2, hh = p.h / 2 + margin / 2
      return [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]].map(([dx, dy]) =>
        [p.x + dx * Math.cos(angle) - dy * Math.sin(angle), p.y + dx * Math.sin(angle) + dy * Math.cos(angle)])
    }
    const p = corners(a), q = corners(b)
    for (const shape of [p, q]) {
      for (let i = 0; i < 4; i++) {
        const next = shape[(i + 1) % 4]
        const axis = [-(next[1] - shape[i][1]), next[0] - shape[i][0]]
        const first = p.map((v) => v[0] * axis[0] + v[1] * axis[1]), second = q.map((v) => v[0] * axis[0] + v[1] * axis[1])
        if (Math.max(...first) <= Math.min(...second) || Math.max(...second) <= Math.min(...first)) return false
      }
    }
    return true
  }

  /**
   * Where each word comes from, and how. A line has one way in: along the reading direction,
   * rising, dropping, from the side its row is aligned to, alternating by row, or out of the
   * centre; specials enter along their own shape. Some words then break away (out of the
   * centre, from their nearest side, or the opposite way), every direction is turned a little,
   * and each word draws its own manner: slide, zoom, spin, zip or fall.
   */
  function enter(parts, archetype, hero, align, c, draws) {
    const set = (p, x, y) => {
      const length = Math.hypot(x, y)
      if (length <= 0.0001) { p.ex = 0; p.ey = 1; return }
      p.ex = x / length; p.ey = y / length
    }
    const cx = sum(parts.map((p) => p.x)) / parts.length, cy = sum(parts.map((p) => p.y)) / parts.length
    let shaped = true
    switch (archetype) {
      case ORBIT: case SPIRAL: {
        const inward = draws.chance(0.5) ? 1 : -1
        parts.forEach((p, i) => { if (i !== hero) set(p, (p.x - cx) * inward, (p.y - cy) * inward) })
        set(parts[hero], 0, 1)
        break
      }
      case COLUMNS: for (const p of parts) set(p, 0, -1); break
      case CASCADE: for (const p of parts) set(p, -0.8, -0.6); break
      case ARC: case WAVE:
        // Along the curve, as if the line were drawn from its start.
        for (const p of parts) { const angle = p.tilt * Math.PI / 180; set(p, -Math.cos(angle), -Math.sin(angle)) }
        break
      case STEPS:
        // Columns drop in and rise in by turns.
        parts.forEach((p, i) => set(p, 0, i % 2 === 0 ? -1 : 1))
        break
      case CALM:
        // Quiet lines rise gently and slide, nothing more.
        for (const p of parts) {
          const turn = (draws.next() - 0.5) * 0.2
          set(p, Math.sin(turn), Math.cos(turn))
          p.mode = 0
        }
        return
      default:
        shaped = false
    }
    if (!shaped) {
      const mode = draws.pick([1.4, 1.2, 0.4 + 0.5 * c, 0.8, 0.6 * c, 0.6 * c])
      // Rows, by their vertical position, for the alternating mode.
      const rowKeys = Array.from(new Set(parts.map((p) => roundAway(p.y / 40)))).sort((a, b) => a - b)
      for (const p of parts) {
        switch (mode) {
          case 0: set(p, -1, 0.15); break
          case 1: set(p, 0, 1); break
          case 2: set(p, 0, -1); break
          case 3:
            if (p.vertical) set(p, 0, -1)
            else set(p, align === 0 ? -1 : (align === 2 ? 1 : 0), align === 1 || align === 3 ? 1 : 0.1)
            break
          case 4: {
            const row = Math.max(0, rowKeys.indexOf(roundAway(p.y / 40)))
            set(p, row % 2 === 0 ? -1 : 1, 0.1)
            break
          }
          default: set(p, p.x - cx, p.y - cy)
        }
        if (p.vertical && mode !== 5) set(p, 0, -1)
      }
      if (mode !== 5) set(parts[hero], parts[hero].ex * 0.5, parts[hero].ey * 0.5 + 0.5)
    }

    const breakaway = (shaped ? 0.12 : 0.22) + (shaped ? 0.18 : 0.33) * c
    parts.forEach((p, i) => {
      if (parts.length > 1 && draws.chance(breakaway)) {
        switch (draws.pick([1, 1, 0.8, 0.6])) {
          case 0: set(p, p.x - cx, p.y - cy); break
          case 1: set(p, p.x >= cx ? 1 : -1, (draws.next() - 0.5) * 0.4); break
          case 2: set(p, (draws.next() - 0.5) * 0.4, p.y >= cy ? 1 : -1); break
          default: set(p, -p.ex, -p.ey)
        }
      }
      const turn = (draws.next() - 0.5) * (0.3 + 0.5 * c)
      const ex = p.ex, ey = p.ey
      set(p, ex * Math.cos(turn) - ey * Math.sin(turn), ex * Math.sin(turn) + ey * Math.cos(turn))
      // Chinese leans to the quiet manners; rich lines use all five.
      const manners = p.cjk
        ? [2, 0.5 + 0.6 * c, 0.15 + 0.45 * c, 0.3 + 0.4 * c, 0.3 * c]
        : [1.6, 0.5 + 0.6 * c, 0.2 + 0.7 * c, 0.4 * c, 0.4 * c]
      p.mode = i === hero && draws.chance(0.35) ? 1 : draws.pick(manners)
    })
  }

  return { line }
})()

function layoutLine(words, options) {
  return KineticLayout.line(Array.isArray(words) ? words : [], options || {})
}
