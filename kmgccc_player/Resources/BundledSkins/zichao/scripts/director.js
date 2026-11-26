// 字潮: director
//
// The decisions made once per lyric line or interlude, so the scene's JSON only draws. The
// scene keeps the results in state and calls these from its `latch` watches:
//
//   nextLine(prev, input)       → the line record kept in `state.line`
//   nextInterlude(prev, input)  → the interlude record kept in `state.gap`
//
// Both return `prev` unchanged when nothing should change, so the scene does not redraw.
// Random choices use hash01, the same hash as the expression `random()`, seeded by the line
// index, so a line looks the same every time it is played.
//
// Units: layout units (100 = one em at size 1); the scene multiplies by
// `let.unit` = viewport.min × 0.00066 × line.k.

var Director = (function () {
  'use strict'

  const UNIT = 0.00066
  const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x))
  const num = (v, fallback) => (typeof v === 'number' && isFinite(v) ? v : fallback)

  // The expression language's `random(x)`: a 64-bit mix of round(x × 1000), as 0..<1.
  const bits = new Float64Array(1), word = new BigUint64Array(bits.buffer)
  const MASK = (1n << 64n) - 1n
  function hash01(value) {
    const scaled = value * 1000
    bits[0] = Math.sign(scaled) * Math.round(Math.abs(scaled))
    let x = word[0]
    x = ((x ^ (x >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK
    x = ((x ^ (x >> 27n)) * 0x94d049bb133111ebn) & MASK
    x ^= x >> 31n
    return Number(x % 1000000n) / 1000000
  }

  // MARK: Voices

  // A line sung by every voice at once (the TTML convention for a group agent).
  const TOGETHER = /^v1000$/i

  const lineStart = (line) => num(line && line.start, 0)
  const lineEnd = (line) => Math.max(lineStart(line), num(line && line.end, 0))
  const wordsOf = (line) => (line ? (Array.isArray(line.words) && line.words.length ? line.words : [line]) : [])
  const inkCount = (line) => (line ? Array.from(String(line.text ?? '')).filter((ch) => !/\s/u.test(ch)).length : 0)

  /** Who sings a line: the agent, the side the lyrics put it on, and whether all sing it. */
  function voice(line) {
    const agent = line ? String(line.agent ?? '') : ''
    return { agent, side: line && line.isDuet ? 1 : 0, together: TOGETHER.test(agent) }
  }

  /** Whether the singer changes from line `a` to line `b`. */
  function turns(a, b) {
    if (!a || !b) return false
    const va = voice(a), vb = voice(b)
    if (va.together || vb.together) return false
    return va.agent !== vb.agent || va.side !== vb.side
  }

  /**
   * Whether line `b` shares the frame with `a`, the line before it: another singer, and
   * either `a` is still sung well into `b`, or both are short and follow closely (a quick call
   * and answer). Longer exchanges keep a frame each, and the camera turns between them.
   */
  function shares(a, b) {
    if (!turns(a, b) || inkCount(a) + inkCount(b) > 40) return false
    const da = lineEnd(a) - lineStart(a), db = lineEnd(b) - lineStart(b)
    if (lineEnd(a) - lineStart(b) >= Math.max(0.5, 0.2 * Math.min(da, db))) return true
    return lineStart(b) - lineEnd(a) < 0.6 && da <= 2.6 && db <= 2.6
  }

  // MARK: Blocks

  // Backing vocals: their size beside the line and the gap to it. They sit back in depth: the
  // scene lets them trail the camera by z / (1 + z) of its moves, held softly within
  // `PARALLAX` units, and within the gap less `BACKING_CLEAR` toward their line, so the
  // depth shows on every camera move and they never touch the line.
  const BACKING_SCALE = 0.72
  const BACKING_DEPTH = 0.5
  const BACKING_GAP = 96
  const BACKING_CLEAR = 30
  const PARALLAX = 130
  // When the backing vocals move along with the words shown: at most this many moves, at
  // least this far apart (s), each over MOVE_TIME and done just before the words that cause it.
  const MOVES = 3
  const MOVE_SPACING = 1
  const MOVE_TIME = 0.7
  // Two voices in one frame: the space between their blocks.
  const LANE_GAP = 100

  /** An item's box, turned by its tilt (a 90° turn is already in w and h). */
  function itemBox(it) {
    const r = num(it.r, 0)
    const tilt = Math.abs(r - 90 * Math.round(r / 90)) * Math.PI / 180
    const c = Math.cos(tilt), s = Math.sin(tilt)
    const w = it.w * c + it.h * s, h = it.h * c + it.w * s
    return [it.x - w / 2, it.y - h / 2, it.x + w / 2, it.y + h / 2]
  }

  /**
   * Every box an item takes over its line: where it starts, and for backing vocals each place
   * they move to (`p1x`…`p3y`). With `reach`, backing boxes grow by how far the parallax can
   * carry them (`lx0`, `lx1`, `ly0`, `ly1`), for keeping other lines clear.
   */
  function itemBoxes(it, reach) {
    const b = itemBox(it)
    const out = [b]
    let dx = 0, dy = 0
    for (let k = 1; k <= MOVES; k++) {
      const mx = num(it['p' + k + 'x'], 0), my = num(it['p' + k + 'y'], 0)
      if (!mx && !my) continue
      dx += mx; dy += my
      out.push([b[0] + dx, b[1] + dy, b[2] + dx, b[3] + dy])
    }
    if (!reach || it.b !== 1) return out
    return out.map((q) => [q[0] - num(it.lx0, 0), q[1] - num(it.ly0, 0), q[2] + num(it.lx1, 0), q[3] + num(it.ly1, 0)])
  }

  /** The box covering items over their whole line (see itemBoxes). */
  function bounds(items, reach) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    for (const it of items) {
      for (const q of itemBoxes(it, reach)) {
        x0 = Math.min(x0, q[0]); y0 = Math.min(y0, q[1])
        x1 = Math.max(x1, q[2]); y1 = Math.max(y1, q[3])
      }
    }
    return isFinite(x0) ? [x0, y0, x1, y1] : [0, 0, 0, 0]
  }

  const boxesMeet = (a, b, m) => a[0] < b[2] + m && b[0] < a[2] + m && a[1] < b[3] + m && b[1] < a[3] + m

  /** Moves items (and the backing centre their parallax refers to) by dx, dy. */
  function shift(items, dx, dy) {
    for (const it of items) { it.x += dx; it.y += dy; it.ox += dx; it.oy += dy }
  }

  /**
   * Where the backing vocals go: beside the part of their line shown so far, so they stay by
   * the words being sung rather than past the end of a long line. They keep one side of the
   * line (below; beside a tall one), stay off every word on screen, and move along as more
   * words appear, a little ahead of them. Each place stays on the far side of the words shown
   * so far, so moving there never crosses them.
   *
   * main: the line's words (layout coordinates); bw, bh: the backing block's size; from: when
   * the backing vocals appear. Returns the places (centres) and the moves between them.
   */
  function backingPath(main, bw, bh, from, seed) {
    const area = bounds(main)
    const aw = area[2] - area[0], ah = area[3] - area[1]
    const lean = hash01(seed) < 0.5 ? 1 : -1
    const side = ah > aw * 1.15 ? (lean > 0 ? 1 : 3) : 0 // 0 below, 1 right, 2 above, 3 left
    const appear = main.map((it) => num(it.start, 0) - 0.5)
    // The words shown by a time, framed; the place beside them, drawn a little toward the
    // middle of the whole line so it moves less.
    const place = (shown) => {
      const d = bounds(shown.length ? shown : [main[0]])
      const mx = 0.65 * (d[0] + d[2]) / 2 + 0.35 * (area[0] + area[2]) / 2
      const my = 0.65 * (d[1] + d[3]) / 2 + 0.35 * (area[1] + area[3]) / 2
      const spanX = Math.max(0, aw - bw) / 2, spanY = Math.max(0, ah - bh) / 2
      const cx = (area[0] + area[2]) / 2, cy = (area[1] + area[3]) / 2
      const x = clamp(mx + lean * 0.25 * Math.max(0, d[2] - d[0] - bw) / 2, cx - spanX, cx + spanX)
      const y = clamp(my, cy - spanY, cy + spanY)
      if (side === 0) return [x, d[3] + BACKING_GAP + bh / 2]
      if (side === 2) return [x, d[1] - BACKING_GAP - bh / 2]
      if (side === 1) return [d[2] + BACKING_GAP + bw / 2, y]
      return [d[0] - BACKING_GAP - bw / 2, y]
    }
    // Words appearing after the backing vocals: each may start a move, at most MOVES of
    // them, MOVE_SPACING apart; a word that cannot start one is kept clear by the place before.
    const order = main.map((_, i) => i).sort((a, b) => appear[a] - appear[b])
    const keys = [{ at: from, upto: [] }]
    for (const i of order) {
      const last = keys[keys.length - 1]
      if (appear[i] > from + 0.3 && keys.length <= MOVES && appear[i] - last.at >= MOVE_SPACING) keys.push({ at: appear[i], upto: [i] })
      else last.upto.push(i)
    }
    // Each place keeps clear of every word shown until the next move is done.
    const shown = []
    const places = keys.map((key) => { for (const i of key.upto) shown.push(main[i]); return place(shown) })
    const moves = []
    let at = places[0]
    for (let k = 1; k < keys.length; k++) {
      const dx = places[k][0] - at[0], dy = places[k][1] - at[1]
      if (Math.hypot(dx, dy) < 8) continue
      moves.push({ x: dx, y: dy, a: keys[k].at - MOVE_TIME - 0.15, b: keys[k].at - 0.15 })
      at = places[k]
    }
    // The parallax may carry them this far each way (−x, +x, −y, +y); toward the line, only
    // within the gap.
    const near = BACKING_GAP - BACKING_CLEAR
    const reach = [side === 1 ? near : PARALLAX, side === 3 ? near : PARALLAX, side === 0 ? near : PARALLAX, side === 2 ? near : PARALLAX]
    return { start: places[0], moves, reach }
  }

  /**
   * One line as a block centred on 0: its words, then its backing vocals laid out smaller
   * below it (or beside a tall composition). `lane` lays the line out narrower, for a frame
   * shared with another voice. Every item records its line (`ln`), its number in that line
   * (`q`), the colour it leans to (`c`, 0 the accent, 1 the harmony), whether it is a backing
   * vocal (`b`), its camera depth (`z`) with the centre of its group (`ox`, `oy`).
   */
  function block(line, index, ctx, options) {
    const { p, fonts, width, height, min } = ctx
    const safeW = width * 0.78 / (min * UNIT), safeH = height * 0.62 / (min * UNIT)
    const lane = num(options.lane, 0) > 0
    // A lane takes the frame's width in proportion to its text, so a long line beside a short
    // one is not squeezed into half the frame; it may also break into more rows.
    const laneW = lane ? 0.92 * clamp(num(options.lane, 0.5), 0.3, 0.7) : 1
    const complexity = p.layout === 'simple' ? 0 : 1
    const common = { advance: ctx.advance, font: [fonts.latin || '', fonts.cjk || ''], weight: fonts.weight || 'heavy' }
    const layout = layoutLine(wordsOf(line), Object.assign({}, common, {
      seed: index * 1.618 + ctx.titleLength * 0.37 + ctx.duration * 0.011,
      avoid: options.avoid || [],
      width: safeW * laneW, height: safeH * (lane ? 0.78 : 1),
      // Sharing a frame, the line is tidier and leans on held words for size.
      energy: num(p.accent, 1) * (lane ? 1.1 : 1), complexity: lane ? Math.min(complexity, 0.35) : complexity,
    }))
    const v = voice(line)
    const items = (layout.items || []).map((it, q) => Object.assign({}, it, {
      ln: index, q, b: 0, z: 0, ox: 0, oy: 0, c: ctx.duet ? v.side : 0,
    }))
    const n = items.length
    // A line every voice sings shades from one colour to the other along its words.
    if (v.together && ctx.duet && n > 1) {
      const xs = items.map((it) => it.x), lo = Math.min(...xs), hi = Math.max(...xs)
      for (const it of items) it.c = hi > lo ? (it.x - lo) / (hi - lo) : 0.5
    }

    let size = layout.size || [0, 0]
    let heroBox = layout.heroBox || [0, 0, 0, 0]
    let ghost = layout.ghost || [0, 0, 0]
    let area = [-size[0] / 2, -size[1] / 2, size[0] / 2, size[1] / 2]

    const backing = line && line.background && typeof line.background === 'object' ? line.background : null
    // The brackets lyrics put around backing vocals are dropped: colour, size and depth say it.
    const backWords = wordsOf(backing).map((w) => Object.assign({}, w, { text: String(w.text ?? '') }))
    if (backWords.length) {
      const first = backWords[0], last = backWords[backWords.length - 1]
      first.text = first.text.replace(/^\s*[(（]/u, '')
      last.text = last.text.replace(/[)）]\s*$/u, '')
    }
    const backKept = backWords.filter((w) => w.text.trim() !== '')
    if (n && backKept.length) {
      const back = layoutLine(backKept, Object.assign({}, common, {
        seed: index * 2.713 + ctx.titleLength * 0.29 + 0.5, avoid: [],
        width: safeW * (lane ? laneW : 0.75) / BACKING_SCALE, height: safeH * 0.45 / BACKING_SCALE,
        energy: 0.5, complexity: 0,
      }))
      const bs = back.size || [0, 0]
      const bw = bs[0] * BACKING_SCALE, bh = bs[1] * BACKING_SCALE
      const from = Math.min(...backKept.map((w) => num(w.start, lineStart(backing)))) - 0.5
      const path = backingPath(items.slice(0, n), bw, bh, from, index * 6.37 + 0.41)
      const [bx, by] = path.start
      // Each word carries the moves (`p1x`… delta, `p1a`/`p1b` when) and its parallax reach.
      const moves = {}
      path.moves.forEach((m, k) => {
        const key = 'p' + (k + 1)
        moves[key + 'x'] = m.x; moves[key + 'y'] = m.y; moves[key + 'a'] = m.a; moves[key + 'b'] = m.b
      })
      ;(back.items || []).forEach((it, i) => {
        items.push(Object.assign({}, it, moves, {
          x: bx + it.x * BACKING_SCALE, y: by + it.y * BACKING_SCALE,
          s: it.s * BACKING_SCALE, w: it.w * BACKING_SCALE, h: it.h * BACKING_SCALE,
          role: 0, ln: index, q: n + i, b: 1, z: BACKING_DEPTH, ox: bx, oy: by, c: ctx.duet ? v.side : 1,
          lx0: path.reach[0], lx1: path.reach[1], ly0: path.reach[2], ly1: path.reach[3],
        }))
      })
      area = bounds(items)
    }

    // Centre the whole block, backing included.
    const cx = (area[0] + area[2]) / 2, cy = (area[1] + area[3]) / 2
    shift(items, -cx, -cy)
    size = [area[2] - area[0], area[3] - area[1]]
    heroBox = [heroBox[0] - cx, heroBox[1] - cy, heroBox[2], heroBox[3]]
    ghost = [ghost[0] - cx, ghost[1] - cy, ghost[2]]
    return {
      items, n, size, heroBox, ghost, ghostText: layout.ghostText || '',
      hero: num(layout.hero, -1), heroTime: layout.heroTime || [0, 0], family: num(layout.family, -1),
    }
  }

  // MARK: Camera

  /**
   * Where the camera stands for one line: zoom out when it does not fit, pick a heading away
   * from the last block, stand at least half a screen along it, and choose the spring that
   * gets there. `prev` is the line before it, so the same call predicts the next line while
   * the current one still plays. `line.turn` (a heading, or −1) is set when another singer
   * takes over: the camera crosses to their side.
   */
  function placeCamera(prev, line) {
    const px = Math.abs(num(prev.cam.x, 0)) < 100000 ? num(prev.cam.x, 0) : 0
    const py = Math.abs(num(prev.cam.y, 0)) < 100000 ? num(prev.cam.y, 0) : 0
    const prevSize = prev.index < 0 ? [0, 0] : (prev.size || [0, 0])
    const rand = (a, b) => hash01(line.index * a + b)
    const size = line.size || [0, 0]
    const scale = line.min * UNIT * line.k

    const fit = Math.min(line.width * 0.8 / Math.max(1, scale * size[0]), line.height * 0.68 / Math.max(1, scale * size[1]))
    let zoom = fit < 1 ? Math.max(0.3, fit) : (fit > 1.9 && rand(4.91, 0.27) < 0.3 ? 1.12 + 0.1 * rand(5.3, 0.8) : 1)

    // Now and then a line is shot on a slant: a large in-plane rotation for that one line,
    // never two lines running, never on a change of singer, only on a line sung long enough
    // to be seen. The camera pulls out until the rotated block still fits.
    const spinOn = prev.index >= 0 && num(prev.cam.spin, 0) === 0 && num(line.turn, -1) < 0
      && num(line.span, 0) >= 1.6 && rand(6.37, 0.41) < num(line.spinChance, 0)
    const spin = spinOn ? (rand(7.13, 0.19) < 0.5 ? -1 : 1) * (12 + 10 * rand(8.21, 0.33)) * num(line.spinAngle, 1) : 0
    if (spin !== 0) {
      const a = Math.min(Math.PI / 2, Math.abs(spin) * Math.PI / 180), c = Math.cos(a), s = Math.sin(a)
      const rw = size[0] * c + size[1] * s, rh = size[0] * s + size[1] * c
      const turned = Math.min(line.width * 0.8 / Math.max(1, scale * rw), line.height * 0.68 / Math.max(1, scale * rh))
      zoom = Math.max(0.3, Math.min(zoom, turned))
    }

    // Heading: 0 down, 1 right, 2 left, 3 up. The camera keeps going one way and turns on
    // accents or by chance, turning back before it strays too far.
    const prevHead = num(prev.cam.head, 0)
    let head
    if (prev.index < 0) head = 0
    else if (num(line.turn, -1) >= 0) head = line.turn
    else if (prevHead === 0 && py > 1400) head = 3
    else if (prevHead === 3 && py < -1400) head = 0
    else if ((prevHead === 1 || prevHead === 2) && Math.abs(px) > 900) head = py > 0 ? 3 : 0
    else if (line.hit || rand(3.17, 0.3) < 0.28) {
      head = prevHead === 0 || prevHead === 3
        ? (px > 250 ? 2 : (px < -250 ? 1 : (rand(5.71, 0.6) < 0.5 ? 1 : 2)))
        : (py > 0 ? 3 : 0)
    } else head = prevHead

    // The new line stands at least half a screen away along the heading, so the old one leaves.
    const vertical = head === 0 || head === 3
    const stepX = Math.max((prevSize[0] + size[0]) / 2 + 110, line.width * 0.5 / (scale * zoom))
    const stepY = Math.max((prevSize[1] + size[1]) / 2 + 130, line.height * 0.5 / (scale * zoom))
    const x = prev.index < 0 ? px
      : (vertical ? px * 0.8 + (rand(2.9, 0.7) - 0.5) * Math.min(Math.max(prevSize[0], size[0]) * 0.3, 360)
        : px + (head === 1 ? 1 : -1) * stepX)
    const y = prev.index < 0 ? py
      : (vertical ? py + (head === 0 ? 1 : -1) * stepY
        : py + (rand(3.9, 0.2) - 0.5) * Math.min(Math.max(prevSize[1], size[1]) * 0.5, 300))
    // Longer moves take a slower spring; an accent snaps.
    const travel = Math.max(Math.abs(x - px) / line.width, Math.abs(y - py) / line.height) * scale * zoom
    const curve = prev.index < 0 || line.dur < 1.8 ? 'camLine'
      : (line.hit ? 'camSnap' : (line.dur < 3 || travel < 0.75 ? 'camLineSlow' : 'camLineLong'))
    // The backdrop scrolls by the same moves, in unscaled units, without end.
    const scroll = (prevValue, delta) => num(prevValue, 0) + (Math.abs(delta) < 100000 ? delta * line.k : 0)
    return {
      x, y, zoom, curve, head, roll: 0, spin,
      scrollX: scroll(prev.cam.scrollX, x - px), scrollY: scroll(prev.cam.scrollY, y - py),
    }
  }

  /**
   * The camera for two voices in one frame: it aims at both blocks (`x`, `y`, already placed
   * beside the partner line) and zooms out only as far as they need. No heading change: the
   * partner stays where it was, so the move is short and slow.
   */
  function placePair(prev, line, x, y, shot) {
    const px = Math.abs(num(prev.cam.x, 0)) < 100000 ? num(prev.cam.x, 0) : 0
    const py = Math.abs(num(prev.cam.y, 0)) < 100000 ? num(prev.cam.y, 0) : 0
    const size = line.size || [0, 0]
    const scale = line.min * UNIT * line.k
    const fit = Math.min(line.width * 0.8 / Math.max(1, scale * size[0]), line.height * 0.68 / Math.max(1, scale * size[1]))
    const scroll = (prevValue, delta) => num(prevValue, 0) + (Math.abs(delta) < 100000 ? delta * line.k : 0)
    return {
      // A shot that pulls out goes no further than its own zoom, or the fit if that is less.
      x, y, zoom: Math.max(0.3, Math.min(1, fit, shot.zoom)), roll: shot.roll,
      curve: prev.index < 0 || line.dur < 1.8 ? 'camLine' : 'camLineSlow',
      head: num(prev.cam.head, 0),
      scrollX: scroll(prev.cam.scrollX, x - px), scrollY: scroll(prev.cam.scrollY, y - py),
    }
  }

  // Shots for two voices in one frame, picked per exchange and kept while it lasts:
  //   0 two-shot: side by side, the answer a little lower;
  //   1 diagonal: one high on one side, the other low on the other; the camera pulls out and
  //     leans against the diagonal, then rights itself when the exchange ends;
  //   2 dialogue: one under the other, staggered toward each singer's side, a slight lean.
  // `push` is the way the answer moves on if a line still leaving is in its place.
  const SHOTS = [
    { weight: 0.35, zoom: 1, lean: 0, push: [0, 1] },
    { weight: 0.4, zoom: 0.84, lean: 5.5, push: [0.6, 1] },
    { weight: 0.25, zoom: 0.94, lean: 1.8, push: [0, 1] },
  ]

  /**
   * Where the answering line goes beside its partner, both as boxes in world units: `p` the
   * partner, `c` the answer centred on 0, `others` the boxes of lines still leaving. Returns the
   * answer's centre.
   */
  function stage(kind, side, p, c, others, u) {
    const pw = p[2] - p[0], ph = p[3] - p[1], cw = c[2] - c[0], ch = c[3] - c[1]
    const pcx = (p[0] + p[2]) / 2, pcy = (p[1] + p[3]) / 2
    // The answer's box centre sits at (x, y); c need not be centred on 0.
    const ccx = (c[0] + c[2]) / 2, ccy = (c[1] + c[3]) / 2
    let x, y
    if (kind === 1) {
      x = pcx + side * (0.6 * (pw + cw) / 2 + 40)
      y = pcy + (ph + ch) / 2 + 70
    } else if (kind === 2) {
      x = pcx + side * 0.3 * (pw + cw) / 2
      y = pcy + (ph + ch) / 2 + 56
    } else {
      x = pcx + side * ((pw + cw) / 2 + LANE_GAP)
      y = pcy + (0.15 + 0.3 * u) * (ph + ch) / 2
    }
    const push = SHOTS[kind].push
    const len = Math.hypot(push[0], push[1])
    const dx = side * push[0] / len, dy = push[1] / len
    const at = (x0, y0) => [x0 - cw / 2, y0 - ch / 2, x0 + cw / 2, y0 + ch / 2]
    for (let k = 0; k < 120 && others.some((o) => boxesMeet(at(x, y), o, 50)); k++) { x += dx * 40; y += dy * 40 }
    return [x - ccx, y - ccy]
  }

  // Accent effects and how often each comes up: 0 flash, 1 glow + flare, 2 rings, 3 glitch,
  // 4 disk, 5 glyph glow.
  const EFFECT_WEIGHTS = [1, 0.8, 0.25, 0.7, 0.6, 1]
  // Lines between two defocus hunts at the least: the one that hunted and three after it stay sharp.
  const FOCUS_GAP = 4
  function pickEffect(u) {
    const total = EFFECT_WEIGHTS.reduce((a, b) => a + b, 0)
    let t = u * total
    for (let i = 0; i < EFFECT_WEIGHTS.length; i++) {
      t -= EFFECT_WEIGHTS[i]
      if (t < 0) return i
    }
    return EFFECT_WEIGHTS.length - 1
  }

  // The gap between the lyric block and its translation, in layout units.
  const CAPTION_GAP = 56

  /**
   * The translation under a line: font size, wrap width and the box it fills, in layout
   * units, measured the way the slot draws it (medium weight, two rows at most). Null when
   * the line has none or translations are hidden.
   */
  function caption(line, size, ctx) {
    const text = line ? String(line.translation ?? '').trim() : ''
    if (!text || !ctx.translate) return null
    const unit = ctx.min * UNIT * ctx.k
    // The translation's own font, weight and size relative to the lyric (custom fonts follow
    // the App's translation settings; the presets use the lyric's CJK face in medium).
    const font = ctx.fonts.tr || ctx.fonts.cjk || ''
    const weight = ctx.fonts.trw || 'medium'
    const fontSize = Math.max(14, ctx.min * 0.026 * ctx.k * num(ctx.fonts.trk, 1)) / unit
    const tracking = ctx.min * 0.0012 / unit
    const textWidth = host.measureText(text, fontSize, weight, font) + tracking * Array.from(text).length
    const wrap = Math.max(ctx.width * 0.3, Math.min(ctx.width * 0.6, unit * size[0] * 1.1)) / unit
    const rows = textWidth > wrap * 1.01 ? 2 : 1
    const h = rows * host.lineHeight(font, weight, fontSize)
    return {
      text, size: fontSize, wrap, w: Math.min(textWidth, wrap), h,
      y: size[1] / 2 + CAPTION_GAP + h / 2,
      start: num(line.start, 0),
    }
  }

  /** What every line of one call shares: viewport, fonts and parameters. */
  function context(input) {
    const p = input.params || {}
    const fonts = input.fonts || {}
    return {
      p, fonts,
      width: num(input.width, 1), height: num(input.height, 1), min: num(input.min, 1),
      k: num(p.size, 1),
      titleLength: Array.from(String(input.title ?? '')).length,
      duration: num(input.duration, 0),
      advance: p.font === 'yisong' ? 1.08 : (p.font === 'songti' ? 1.4 : 1.22),
      translate: input.translate !== false,
      track: String(input.track ?? ''),
      duet: !!input.duet,
    }
  }

  /**
   * The full record of one line after `prev`. Everything but the timing (`t0`, `dur`, `out`
   * and the camera spring) depends only on the line, `prev` and `ctx`, so composing the next
   * line ahead of time gives the same words in the same places as composing it when it starts.
   */
  function compose(prev, index, line, ctx, now, dur, near) {
    const { p, fonts, width, height, min, k } = ctx
    const r = (a, b) => hash01(index * a + b)
    const text = line ? String(line.text ?? '') : ''
    const start = lineStart(line), end = lineEnd(line)

    // Where the previous line stood; a fresh start has none. The camera aims at the block
    // with its translation, so the next step starts from that aim.
    const prevIndex = num(prev.index, -2)
    const prevCam = prev.cam || {}
    const prevBox = prevIndex < 0 ? [0, 0] : (prev.box || prev.size || [0, 0])
    const prevItems = prevIndex === index - 1 && prev.track === ctx.track && Array.isArray(prev.items) ? prev.items : null

    // How long the old line takes to leave.
    const out = Math.min(dur * 0.9, clamp(dur * 0.6, 1, 2.6))

    // Another voice: sharing this frame with the line before, or about to share it with the
    // line after; either way this line is laid out narrow.
    // `lane` is this line's share of the frame's width (0 for a frame of its own).
    const before = near.before || null, after = near.after || null
    const partnerLine = shares(before, line) ? before : null
    const share = (a, b) => inkCount(b) / Math.max(1, inkCount(a) + inkCount(b))
    const lane = Math.max(partnerLine ? share(before, line) : 0, shares(line, after) ? share(after, line) : 0)

    // Composition: this line and its backing vocals, centred on 0.
    const own = block(line, index, ctx, { lane, avoid: [num(prev.family, -1), num(prev.prevFamily, -1)] })
    let items = own.items
    let size = own.size
    const n = own.n
    const hero = own.hero
    const heroTime = own.heroTime
    const heroItem = hero >= 0 ? items[hero] : null

    // The line before, still on screen, keeps its place; this line answers it in one of the
    // SHOTS, on its singer's side and below or beside it, so the two read in the order they
    // are sung, and clear of any line still leaving. Its items come after this line's own, so
    // `lyrics.wordIndex` still indexes this line's words.
    let partner = -1, pairAim = null, shot = -1, roll = 0, others = []
    if (partnerLine) {
      partner = index - 1
      let carried = prevItems ? prevItems.filter((it) => it.ln === partner).map((it) => Object.assign({}, it)) : []
      let origin = [num(prevCam.x, 0), num(prevCam.y, 0)]
      if (carried.length) {
        // Lines on screen with the partner (the exchange before it) leave as this one comes.
        others = prevItems.filter((it) => it.ln !== partner)
          .flatMap((it) => itemBoxes(it, true))
          .map((q) => [q[0] + origin[0], q[1] + origin[1], q[2] + origin[0], q[3] + origin[1]])
      } else {
        // Seeked into the middle of an exchange: lay the partner out again where the camera is.
        carried = block(partnerLine, partner, ctx, { lane: share(line, partnerLine), avoid: [] }).items
        origin = [num(prevCam.x, 0), num(prevCam.ay, num(prevCam.y, 0))]
      }
      if (!carried.length) partner = -1
      else {
        // An exchange keeps its shot; a new one picks one and its lean.
        const chain = prevIndex === index - 1 && num(prev.partner, -1) >= 0 && num(prev.shot, -1) >= 0
        const u = r(5.83, 0.27) * SHOTS.reduce((a, s) => a + s.weight, 0)
        let pick = 0
        for (let acc = 0; pick < SHOTS.length - 1 && u >= (acc += SHOTS[pick].weight); pick++);
        shot = chain ? num(prev.shot, 0) : pick
        const side = voice(line).side ? 1 : -1
        const pb = bounds(carried, true)
        const p = [origin[0] + pb[0], origin[1] + pb[1], origin[0] + pb[2], origin[1] + pb[3]]
        const at = stage(shot, side, p, bounds(items, true), others, r(6.21, 0.4))
        // Against the diagonal (it reads flatter), now and then with it; an exchange going on
        // settles back halfway each line.
        const lean = SHOTS[shot].lean * (0.8 + 0.4 * r(7.13, 0.2)) * (r(7.61, 0.9) < 0.75 ? -side : side)
        roll = chain ? 0.5 * num(prevCam.roll, 0) : lean
        const own0 = bounds(items), part0 = bounds(carried)
        const ux0 = Math.min(origin[0] + part0[0], at[0] + own0[0]), ux1 = Math.max(origin[0] + part0[2], at[0] + own0[2])
        const uy0 = Math.min(origin[1] + part0[1], at[1] + own0[1]), uy1 = Math.max(origin[1] + part0[3], at[1] + own0[3])
        const ux = (ux0 + ux1) / 2, uy = (uy0 + uy1) / 2
        shift(items, at[0] - ux, at[1] - uy)
        shift(carried, origin[0] - ux, origin[1] - uy)
        own.heroBox = [own.heroBox[0] + at[0] - ux, own.heroBox[1] + at[1] - uy, own.heroBox[2], own.heroBox[3]]
        own.ghost = [own.ghost[0] + at[0] - ux, own.ghost[1] + at[1] - uy, own.ghost[2]]
        items = items.concat(carried)
        size = [ux1 - ux0, uy1 - uy0]
        pairAim = [ux, uy]
      }
    }
    // Order: this line's words, the partner's, this line's backing vocals, the partner's. The
    // words draw in one slot layer (`nm` of them); each backing group in a layer of its own,
    // which moves it along (`backs[g]` p1x…) and gives it parallax with the live camera.
    const ownMain = items.filter((it) => it.b !== 1 && it.ln === index)
    const partMain = items.filter((it) => it.b !== 1 && it.ln !== index)
    const ownBack = items.filter((it) => it.b === 1 && it.ln === index)
    const partBack = items.filter((it) => it.b === 1 && it.ln !== index)
    items = ownMain.concat(partMain, ownBack, partBack)
    const nm = ownMain.length + partMain.length, nb = ownBack.length
    const group = (list) => {
      const it = list[0]
      if (!it) return {}
      const g = { ox: it.ox, oy: it.oy, z: it.z, lx0: it.lx0, lx1: it.lx1, ly0: it.ly0, ly1: it.ly1 }
      for (let k = 1; k <= MOVES; k++) for (const f of ['x', 'y', 'a', 'b']) if (it['p' + k + f] !== undefined) g['p' + k + f] = it['p' + k + f]
      return g
    }
    const backs = [group(ownBack), group(partBack)]
    const heroBox = own.heroBox

    // The accent: a hero held at least 0.7 s gets one of six effects (0 flash, 1 glow + flare,
    // 2 rings, 3 glitch, 4 disk, 5 glyph glow); rarely, the hero flickers or throws echoes.
    // A held hero always gets the camera push; a visible effect only some of the time: 25%,
    // 40% when held 1.4 s or longer, and a quarter of that right after a line that had one.
    // The rings are the loudest effect, so they come up least.
    const held = heroTime[1] - heroTime[0]
    const hit = hero >= 0 && n > 1 && held >= 0.7
    const prevEffect = prevIndex === index - 1 && num((prev.accent || {}).kind, -1) >= 0
    const effect = hit && hash01(index * 6.37 + ctx.titleLength * 0.23 + 0.41) < (held >= 1.4 ? 0.4 : 0.25) * (prevEffect ? 0.25 : 1)
    const accent = {
      on: hit ? 1 : 0,
      start: heroTime[0],
      dur: hero >= 0 ? clamp(held, 0.6, 4) : 1,
      kind: effect ? pickEffect(hash01(index * 7.77 + ctx.titleLength * 0.19 + 0.31)) : -1,
      flash: n > 1 && r(8.93, 0.17) < 0.05 ? (r(9.41, 0.5) < 0.5 ? 1 : 2) : 0,
    }
    // Defocus: now and then the lens loses focus on the accent and hunts for it (the layers'
    // `bokeh` filter). `defocus` is its chance on an accent line; at least FOCUS_GAP lines go by
    // between two hunts however the draws fall (a slow song where every line holds a long note
    // is all accent lines, and luck alone put a hunt every third line); never on the two glow
    // effects, whose bloom already fills the frame.
    const sinceFocus = prevIndex === index - 1 ? num((prev.accent || {}).sinceFocus, FOCUS_GAP) + 1 : FOCUS_GAP
    const focus = hit && accent.kind !== 1 && accent.kind !== 5 && sinceFocus >= FOCUS_GAP
      && hash01(index * 5.11 + ctx.titleLength * 0.29 + 0.73) < num(p.defocus, 0.05)
    accent.sinceFocus = focus ? 0 : Math.min(sinceFocus, FOCUS_GAP)
    accent.focusAt = focus ? heroTime[0] : null
    accent.focusSeed = Math.round(hash01(index * 3.17 + ctx.titleLength * 0.13 + 0.59) * 1000)
    // Springy lines bounce at the full setting; the rest barely. Each word keeps the bounce of
    // its own line (`eb`), so a carried partner settles the way it began.
    const springy = hit || r(4.37, 0.15) < 0.45 ? 1 : 0.2
    const bounce = num(p.bounce, 0.2) * springy
    // Each word also keeps its line's accent effect (`ak`) and timing (`as` start, `ad` length),
    // so a carried partner keeps its glow and lets it fade out on its own schedule instead of
    // being cut when the answering line takes over the slot.
    for (let i = 0; i < own.items.length; i++) {
      own.items[i].eb = bounce
      own.items[i].ak = accent.kind
      own.items[i].as = accent.start
      own.items[i].ad = accent.dur
    }

    // The translation hangs under the block; the camera frames both and aims at their middle.
    // `cam.x`/`cam.y` stay the lyric block's origin, `cam.ay` is where the camera points.
    const cap = caption(line, size, ctx)
    const box = cap ? [Math.max(size[0], cap.w), size[1] + CAPTION_GAP + cap.h] : size
    const lift = cap ? (CAPTION_GAP + cap.h) / 2 : 0
    const camPrev = {
      index: prevIndex, size: prevBox,
      cam: { x: prevCam.x, y: num(prevCam.ay, num(prevCam.y, 0)), head: prevCam.head, scrollX: prevCam.scrollX, scrollY: prevCam.scrollY, spin: prevCam.spin },
    }
    // A longer exchange keeps a frame per singer: the camera crosses to the new singer's side
    // (right for the second voice, left for the first) instead of carrying on its way.
    const turn = !partnerLine && ctx.duet && prevIndex >= 0 && turns(before, line) ? (voice(line).side ? 1 : 2) : -1
    const placed = pairAim
      ? placePair(camPrev, { size: box, dur, width, height, min, k }, pairAim[0], pairAim[1] + lift, { zoom: SHOTS[shot].zoom, roll })
      : placeCamera(camPrev, { index, size: box, hit, dur, width, height, min, k, turn,
        span: end - start, spinChance: num(p.spinChance, 0.08), spinAngle: num(p.spinAngle, 1) })
    // A line of its own steps at least half a screen away; if the line before still reaches
    // it (hanging punctuation, backing vocals and their parallax), it steps on further.
    if (!pairAim && prevItems) {
      const head = num(placed.head, 0)
      const step = [head === 1 ? 1 : (head === 2 ? -1 : 0), head === 0 ? 1 : (head === 3 ? -1 : 0)]
      const old = prevItems.flatMap((it) => itemBoxes(it, true))
        .map((q) => [q[0] + num(prevCam.x, 0), q[1] + num(prevCam.y, 0), q[2] + num(prevCam.x, 0), q[3] + num(prevCam.y, 0)])
      const mine = items.flatMap((it) => itemBoxes(it, true))
      const clash = () => mine.some((q) => old.some((o) => boxesMeet([q[0] + placed.x, q[1] + placed.y - lift, q[2] + placed.x, q[3] + placed.y - lift], o, 40)))
      for (let i = 0; i < 80 && clash(); i++) {
        placed.x += step[0] * 40; placed.y += step[1] * 40
        placed.scrollX += step[0] * 40 * k; placed.scrollY += step[1] * 40 * k
      }
    }
    const cam = Object.assign({}, placed, { y: placed.y - lift, ay: placed.y, lift })
    // Where the camera rests on each backing group's own line (`cx`, `cy`): the scene measures
    // their parallax from there, so a group carried into the next line's frame keeps its place.
    if (backs[0].z !== undefined) { backs[0].cx = cam.x; backs[0].cy = cam.ay }
    if (backs[1].z !== undefined) {
      const pb = (prev.backs || [])[0] || {}
      backs[1].cx = num(pb.cx, num(prevCam.x, 0)); backs[1].cy = num(pb.cy, num(prevCam.ay, num(prevCam.y, 0)))
    }

    // Which way the line before leaves (a unit vector, for the whole of its slot): away from
    // where the camera now looks, along the main axis of the move. In an exchange, the lines
    // still leaving go straight away from the new pair, so they never cross it.
    let leave = null
    if (prevIndex === index - 1) {
      let dx = num(prevCam.x, 0) - cam.x, dy = num(prevCam.ay, num(prevCam.y, 0)) - cam.ay
      if (partner >= 0 && others.length) {
        const o = others.reduce((a, q) => [Math.min(a[0], q[0]), Math.min(a[1], q[1]), Math.max(a[2], q[2]), Math.max(a[3], q[3])], [Infinity, Infinity, -Infinity, -Infinity])
        dx = (o[0] + o[2]) / 2 - cam.x; dy = (o[1] + o[3]) / 2 - cam.ay
      } else if (Math.abs(dx) >= Math.abs(dy)) dy = 0
      else dx = 0
      const len = Math.hypot(dx, dy)
      leave = len > 1 ? { on: 1, x: dx / len, y: dy / len } : null
    }

    // Comets: none, around the hero, around the line, or around one more word too.
    const comets = !p.comets || !n ? 0
      : (r(6.7, 0.9) < 0.24 ? 0 : (n < 3 || r(7.3, 0.1) < 0.5 ? 1 : (r(8.1, 0.4) < 0.6 ? 2 : 3)))
    const comet = {
      count: comets,
      angle: heroItem ? Math.atan2(num(heroItem.ey, 1), num(heroItem.ex, 0)) * 180 / Math.PI : 90,
      sweep: r(9.7, 0.3) < 0.5 ? 1 : -1,
      word: Math.min(n - 1, Math.floor(r(2.7, 0.5) * n)),
    }

    // Ornaments ring a single word, and sometimes a hero on its own row.
    const archetype = Math.floor(own.family / 1000)
    const ornament = archetype === 8 || (archetype === 1 && r(5.37, 0.8) < 0.3) ? Math.min(2, Math.floor(r(6.13, 0.4) * 3)) : -1

    // The handoff comet stays an event: at least 8 s after the last one, and on a quick back
    // and forth only some of the time; a singer taking over after three lines or more always
    // gets it. `run` counts the lines the current singer has sung in a row; `handoffAt` is
    // when the last comet arrived.
    const turned = turns(before, line)
    const follows = prevIndex === index - 1
    const run = !turned && follows ? num(prev.run, 1) + 1 : 1
    const lastAt = follows ? num(prev.handoffAt, -100) : -100
    const passes = turned && start - lastAt >= 8 && (follows && num(prev.run, 1) >= 3 || r(3.93, 0.61) < 0.3)
    const passed = passes ? handoff(prevItems, prevCam, cam, items, partner, index, before, line, ctx) : null

    const ghost = own.ghost
    return {
      index, track: ctx.track, text,
      translation: line ? String(line.translation ?? '') : '',
      spread: wordsOf(line).length === 1 && n > 1 ? 1 : 0,
      t0: now, dur, out,
      k,
      font: { latin: fonts.latin || '', cjk: fonts.cjk || '', weight: fonts.weight || 'heavy', tr: fonts.tr || fonts.cjk || '', trw: fonts.trw || 'medium' },
      family: own.family, prevFamily: num(prev.family, -1),
      // `n`: how many of `items` are this line's own words; the rest are its backing vocals
      // and the partner line. `partner`: the line index sharing the frame, or −1.
      size, box, items, n, partner, voice: voice(line).side, lane: lane ? 1 : 0,
      // `shot`: the SHOTS entry of a shared frame, or −1. `leave`: see above.
      shot, leave, nm, nb, backs,
      hero, heroItem,
      heroBox: { x: heroBox[0], y: heroBox[1], w: heroBox[2], h: heroBox[3] },
      accent,
      entry: { bounce, time: num(p.entry, 0.9), min: num(p.entryMin, 0.45) },
      cam, cap, comet, ornament,
      run, handoff: passed, handoffAt: passed ? passed.at : lastAt,
      ghost: { x: ghost[0], y: ghost[1], scale: ghost[2], text: own.ghostText },
      // How long the words take to leave when an interlude begins.
      fade: clamp((end - start) * 0.4, 0.2, 0.9),
    }
  }

  /**
   * When another singer takes over: a comet leaves the word the last singer was on and reaches
   * the new singer's first word as it is sung. In this record's coordinates: the midpoint
   * (`x`, `y`), half the distance (`r`), the direction (`angle`, degrees), when it reaches the
   * new word (`at`) and how long the crossing takes (`span`); `c` is the colour it carries.
   * Null when the singer stays or the previous words are not on screen.
   */
  function handoff(prevItems, prevCam, cam, items, partner, index, before, line, ctx) {
    if (!ctx.p.comets || !items.length || !turns(before, line)) return null
    let source
    if (partner >= 0) source = items.filter((it) => it.ln === partner && it.b === 0)
    else if (prevItems) {
      const dx = num(prevCam.x, 0) - cam.x, dy = num(prevCam.y, 0) - cam.y
      source = prevItems.filter((it) => it.ln === index - 1 && it.b === 0).map((it) => ({ x: it.x + dx, y: it.y + dy, start: it.start, end: it.end }))
    }
    if (!source || !source.length) return null
    const target = items[0]
    const at = num(target.start, lineStart(line))
    const sung = source.filter((it) => num(it.start, 0) <= at - 0.05)
    const from = sung.length ? sung[sung.length - 1] : source[source.length - 1]
    const dx = target.x - from.x, dy = target.y - from.y
    const distance = Math.hypot(dx, dy)
    if (!(distance > 80) || distance > 20000) return null
    return {
      x: (from.x + target.x) / 2, y: (from.y + target.y) / 2, r: distance / 2,
      angle: Math.atan2(dy, dx) * 180 / Math.PI,
      at, span: clamp(at - num(from.end, at) + 0.35, 0.45, 1.1), c: num(target.c, 0),
    }
  }

  /**
   * input: { index, line, next, now, track, title, duration, width, height, min, translate,
   *          before (the line before), after (the line after next), duet (the song has a
   *          second voice), fonts: {latin, cjk, weight}, params: {size, font, layout, accent,
   *          comets, bounce, entry, entryMin} }
   */
  function nextLine(prev, input) {
    prev = prev || {}
    const index = num(input.index, -1)
    const line = input.line || null
    const next = input.next || null
    const now = num(input.now, 0)
    const track = String(input.track ?? '')
    const text = line ? String(line.text ?? '') : ''
    const lineStart = line ? num(line.start, 0) : 0, lineEnd = line ? num(line.end, 0) : 0

    // A new line: another index, track or text. A flash of a line (under 0.25 s, the next one
    // within 0.6 s) is skipped, so the camera does not jump there and straight back.
    const flash = line && lineEnd - lineStart < 0.25 && next && num(next.start, 0) - lineStart < 0.6
    const changed = index !== prev.index || track !== prev.track || text !== prev.text
    if (!changed || flash) {
      if (track !== prev.track) return Object.assign({}, prev, { index: -1, track, upcoming: null, camNext: null })
      return prev
    }

    const ctx = context(input)
    // Until the next line starts.
    const dur = clamp((next ? num(next.start, 0) : (line ? lineEnd : now) + 3) - now, 0.8, 14)
    const record = compose(prev, index, line, ctx, now, dur, { before: input.before || null, after: next })
    // The line before began leaving on the upcoming record's timing; keep it so its exit runs on.
    // `early`: the line before was told this line was next, so it began leaving ahead of it.
    const up = prev.upcoming
    const told = up && up.index === index && up.track === record.track
    record.early = told && prev.camNext ? 1 : 0
    // When the line before leaves: on the time it was told, though after a pause the lyrics
    // switch up to a second ahead of that, so its exit runs on unbroken through the change.
    record.leaveAt = record.early ? num(prev.camNext.at, now) : now
    // The camera set off toward this line on the upcoming record's curve; it keeps that curve,
    // so the move runs on at one speed through the change.
    if (told) {
      record.out = up.out
      record.cam = Object.assign({}, record.cam, { curve: up.cam.curve })
    }

    // The next line, composed while this one plays: the scene puts it in its own slot so its
    // first words enter on time instead of appearing already half in when the line changes,
    // and the camera starts toward it before its first word. Skipped for flashes, which never
    // stand long enough to be shown.
    let upcoming = null, camNext = null
    if (next) {
      const nextStart = num(next.start, 0), nextEnd = num(next.end, 0)
      if (nextStart > now && nextEnd - nextStart >= 0.25) {
        upcoming = compose(record, index + 1, next, ctx, nextStart, clamp(nextEnd - nextStart + 1.2, 0.8, 14),
          { before: line, after: input.after || null })
        const c = upcoming.cam
        camNext = { x: c.x, y: c.ay, zoom: c.zoom, roll: c.roll, spin: num(c.spin, 0), curve: c.curve, k: ctx.k, at: nextStart, scrollX: c.scrollX, scrollY: c.scrollY }
      }
    }
    // Lyrics hidden: the title card stands alone and the backdrop holds still. The line is
    // still framed, so the camera finds it when the lyrics come back.
    if (input.hidden) {
      const prevCam = prev.cam || {}
      record.cam = Object.assign({}, record.cam, { scrollX: num(prevCam.scrollX, 0), scrollY: num(prevCam.scrollY, 0) })
      camNext = null
    }
    // `live`: this record was the current line (an upcoming record never is), for placeSlots.
    return Object.assign(record, { upcoming, camNext, live: 1 })
  }

  /** input: { on, now, left, title } */
  // Each piece of a long interlude stays INTERLUDE_HOLD to INTERLUDE_HOLD + INTERLUDE_SPREAD
  // seconds (`next` is when it may change); a new one comes only while at least INTERLUDE_LAST
  // seconds remain. An interlude longer than INTERLUDE_LONG favours the title.
  const INTERLUDE_HOLD = 30
  const INTERLUDE_SPREAD = 20
  const INTERLUDE_LAST = 20
  const INTERLUDE_LONG = 45
  const pieceHold = (count) => INTERLUDE_HOLD + INTERLUDE_SPREAD * hash01(count * 1.93 + 0.4)

  /**
   * The piece an interlude shows: 0 dots, 1 capsule spectrum, 2 LED meter, 3 title with
   * orbiting dots. A long interlude weighs the title up; a change never repeats the piece before.
   */
  function interludePiece(count, title, long, before) {
    const titleLength = Array.from(String(title ?? '')).length
    const weights = [1, 1, 1, long ? 2.6 : 1]
    if (before >= 0 && before < 4) weights[before] = 0
    const total = weights.reduce((a, b) => a + b, 0)
    let pick = hash01(count * 3.71 + titleLength * 0.53 + 0.2) * total
    let kind = 0
    while (kind < 3 && pick >= weights[kind]) { pick -= weights[kind]; kind++ }
    return {
      kind,
      dots: hash01(count * 2.31 + 0.7) < 0.3 ? 3 : 4 + Math.floor(hash01(count * 3.17 + 0.2) * 5),
    }
  }

  function nextInterlude(prev, input) {
    prev = prev || {}
    const on = input.on ? 1 : 0
    const now = num(input.now, 0)
    const t0 = num(prev.t0, -100000)
    // Seconds until the vocals return, or in an outro until the closing title card; an unknown
    // end counts as long.
    const left = Math.max(0, num(input.left, 100000))
    // Seeking back before the interlude began undoes it.
    const rewound = now < t0 - 0.5
    const fresh = on && (!prev.on || rewound)
    if (fresh) {
      const count = num(prev.count, 0) + 1
      // A seek (often while paused) can land deep inside an interlude. Counting from the real
      // start makes the last line's exit already done, instead of waiting for playback to run it.
      const start = num(input.start, now)
      const since = now - start
      return Object.assign({ on, t0: since > 0.75 ? start : now, next: now + pieceHold(count), count }, interludePiece(count, input.title, left > INTERLUDE_LONG, -1))
    }
    if (rewound) return Object.assign({}, prev, { on, t0: -100000 })
    if (prev.on !== on) return Object.assign({}, prev, { on })
    // A piece that has had its time gives way to another.
    if (!on || now < num(prev.next, 100000) || left < INTERLUDE_LAST) return prev
    const count = num(prev.count, 0) + 1
    return Object.assign({}, prev, { next: now + pieceHold(count), count },
      interludePiece(count, input.title, left + now - t0 > INTERLUDE_LONG, num(prev.kind, -1)))
  }

  /**
   * The three slots after a line change: the line before keeps its slot while it leaves, the
   * new line takes the slot its upcoming record stood in, and its own upcoming line the third.
   * Indices may skip (a flash of a line is passed over), so slots are not picked by index.
   * input: { slots, line }
   */
  function placeSlots(input) {
    const slots = (Array.isArray(input.slots) ? input.slots.slice(0, 3) : []).map((s) => s || {})
    while (slots.length < 3) slots.push({})
    const line = input.line || {}
    const index = num(line.index, -1)
    const ours = (s) => s.track === line.track && num(s.index, -1) >= 0
    let keep = -1
    slots.forEach((s, k) => {
      if (ours(s) && num(s.live, 0) === 1 && num(s.index, -1) < index && (keep < 0 || num(s.index, -1) > num(slots[keep].index, -1))) keep = k
    })
    let here = slots.findIndex((s) => ours(s) && num(s.index, -1) === index)
    if (here < 0 || here === keep) here = [0, 1, 2].find((k) => k !== keep)
    const next = [0, 1, 2].find((k) => k !== keep && k !== here)
    slots[here] = line
    slots[next] = line.upcoming || {}
    return slots
  }

  return { nextLine, nextInterlude, placeSlots }
})()

function nextLine(prev, input) { return Director.nextLine(prev, input || {}) }
function nextInterlude(prev, input) { return Director.nextInterlude(prev, input || {}) }
function placeSlots(input) { return Director.placeSlots(input || {}) }
