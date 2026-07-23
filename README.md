# Audience Wonderland Text Orientation

Detect the angle a person wrote at on an impression pad, and return the strokes rotated
upright, ready to feed a recognizer such as MyScript iink. It handles any angle, tall or
short letters, cursive, all caps, lone digits, and multiple lines, in a single geometric
pass. No recognition search.

This is v3. Everything in it earned its place on a benchmark, and I removed the parts of my
own earlier method that the benchmark proved were dead weight. The full story is below.

## The problem I set out to solve

A spectator writes on the pad from wherever they are standing. The strokes arrive in
whatever direction they wrote, and the recognizer has no idea. This is not a corner the
recognizers forgot to handle: MyScript's own staff confirm the engine cannot infer
orientation, MLKit assumes upright ink, and Apple's Vision requires the caller to supply
the orientation. Somebody upstream has to rotate the ink upright first. That somebody is
this file.

The obvious fix is to run recognition in all four directions and keep the best answer.
That works, but every attempt costs a full recognition pass, and it can only ever snap to
four directions. I wanted the opposite: read the geometry of the strokes once, compute the
exact angle, rotate once, recognize once.

## How I built it, start to finish

**Step 1: the core idea.** I take the center point of each stroke. The center of a tall
letter sits at its middle, on the text midline, so across a word the centroids line up
along the baseline no matter how tall or narrow the letters are. A PCA fit of those
centroids gives me the baseline angle at any angle, not just the four cardinals. That
leaves four possible readings of that axis (which end is up, which way do you read), so I
score all four for how much they read like text and keep the winner. Confidence is how far
the winner beat the runner-up. Low confidence means the geometry genuinely cannot tell, and
the system says "don't know" instead of guessing, so the app can fall back to a recognition
retry. I verified this version on my own Lumen Trilogy: a rotation sweep at every 10
degrees came back 180 for 180, worst case 2 degrees off, zero upside-down flips.

**Step 2: check my method against the literature.** Before trusting it further I ran a
deep prior-art sweep: published methods for handwriting orientation going back twenty
years (Nakagawa and Onuma's direction histograms, Leptonica's flip detector, Tesseract's
orientation voting, dynamic-programming line grouping, skew estimation, and more), with
every claim verified against its source. The sweep confirmed the architecture: geometric
pre-rotation feeding a single recognition pass is exactly the contract the recognizers
expect. It also handed me a shortlist of candidate upgrades.

**Step 3: measure everything.** I built a benchmark instead of arguing with myself. Every
sample gets rotated through all 36 ten-degree steps plus 20 random angles, and the detector
has to recover the rotation. The test data is 20 real impressions captured from my Trilogy
plus 600 samples from the DeepWriting handwriting dataset: 300 single words and 300 lone
characters, which is exactly the short, context-free input a spectator produces. Then I
implemented every candidate upgrade and let the numbers decide.

**What survived:**

- **Pen-direction histogram** (after Nakagawa and Onuma). Pen-down strokes mostly travel
  down the glyph axis, and pen-up jumps advance along the reading direction. Two
  histograms, built once, tell you which way is down even for a single glyph with no
  baseline at all. This is the biggest single upgrade in v3, and at heavy weight it powers
  the new lone-glyph path.
- **Projection-profile sharpness.** At the correct rotation, ink collapses into tight
  horizontal bands; at the wrong one it smears. A capped histogram sharpness score captures
  that, and it is strongest exactly where the centroid baseline is weakest: short,
  square-aspect input.
- **Smarter line clustering.** I replaced my fragile median-height line-gap rule with a
  robust character-size estimate (Onuma) plus temporal breaks from long pen-up jumps. This
  alone took real-pad accuracy from 97.2% to 99.4%.
- **A new lone-glyph rule.** For 1 or 2 strokes there is no baseline, so v3 blends glyph
  tallness, my start-is-up prior (people begin a 6 and a 9 at the top), and the direction
  histogram, then fine-nudges the angle from the histogram's down peak. On lone digits this
  scores 98.5% versus 83.3% for my earlier rule.

**What I tested and threw away:** a fine-skew regression stage (zero measured gain),
Leptonica-style confidence gates (no better than a plain calibrated threshold), the
DP line-grouping cost (weight tuned itself to zero, slowest feature), an
ascender-descender up-or-down count (flat), and reading pen tilt off the pad's Bluetooth
protocol (the packets carry only x, y, and pressure, so there is nothing to read). I also
removed my own line-stacking term from v2 after the ablation showed it contributed
nothing. If a term is in this file, it paid for itself on the benchmark; if it is not,
I measured it and it did not.

**Step 4: verify, then port.** An independent verification pass re-ran the winning
configuration from scratch on fresh data and reproduced every number before I accepted it.
This Swift file was then checked against the reference implementation on 260 test cases,
matching to floating-point precision.

## The numbers

Four-way accuracy across the full rotation sweep, v3 versus my previous version:

| Test set | v2 | v3 |
|---|---|---|
| Real pad impressions (words, cursive, multi-line) | 97.2% | 99.5% |
| Single handwritten words (DeepWriting, 300) | 67.1% | 72.7% |
| Lone characters (DeepWriting, 300) | 43.4% | 53.4% |
| Lone digits | 83.3% | 98.5% |

Upside-down flips dropped on every set (lone characters: 22% down to 13%). Runtime is
about 0.6 ms per detection in pure Python on a laptop; this Swift version is faster. When
v3 is unsure it abstains rather than guessing, and abstained input goes to the retry
described below, so a wrong-but-confident answer is rare: on short words, decided output
flips 180 degrees only 1.2% of the time, versus 5.1% for v2.

## Usage

```swift
let result = TextOrientation.detect(strokes)
// result.degrees, .confidence, .abstain, .lineCount, .path

let upright = TextOrientation.normalize(strokes)  // strokes rotated upright

// Feed MyScript. Nothing in your recognition pipeline changes:
let events = TextOrientation.myScriptPointerEvents(strokes)   // (x, y, t) pointer events
let text = myScript.recognize(events)

// Retry when the geometry says "don't know". Run the flipped candidate in
// parallel so even the fallback costs one pass of latency:
if result.abstain {
    let flipped = TextOrientation.apply(upright, rotation: .pi)
    // recognize `flipped` concurrently; keep the better result.
}
```

`Stroke` is `[StrokePoint]`; `StrokePoint` is `(x, y)`. Pressure and timestamps are not
required. Feed strokes in the order they were written; each pen-up ends a stroke. The
coordinate convention is y increasing downward, which is what the pads send.

**Picking the retry winner.** Neither MyScript's JIIX text export nor MLKit exposes numeric
confidence scores for text, so compare the two passes by candidate ranks and lexicon hits:
does one orientation's top answer appear in the other's candidate list, and is one a real
word when the other is junk.

**Free accuracy on the recognizer side.** While digging through the SDKs I found config
levers that cost nothing at runtime: in MyScript, enable `text.guides` and feed it the line
gap this detector already computes, and turn on per-character candidates in the JIIX
export (`text.words` and `text.chars`) so the retry has ranks to compare. In MLKit, pass a
`WritingArea` per line in the rotated frame and the previous line as `preContext`. None of
that is part of this file, but if you are integrating this, do those too.

## Honest limits

- **Diagonal underlines.** I drop underlines and box edges before fitting, but the filter
  only catches them reliably when they arrive near-horizontal or near-vertical. A long
  underline at a diagonal still hurts accuracy. I tried the obvious rotation-invariant fix
  and the benchmark rejected it (it started eating legitimate strokes), so this stays an
  open item.
- **Lone letters** are the hardest input there is (53% four-way). Lone digits are strong,
  and multi-character input is unambiguous, but a single letter with no context is
  genuinely ambiguous even to a human reading rotated ink. The abstain flag and the retry
  carry this case.
- **Unusual stroke order.** The lone-glyph path leans on people starting glyphs near the
  top. Someone who draws a 6 bottom-up can still fool it; the direction histogram usually
  catches it now, but it is a strong aid, not a guarantee.

## Examples

Twelve varied words written at random orientations, all normalized upright:

![words before and after](docs/words-before-after.png)

Lone digits (6 and 9) at varied orientations, recovered upright:

![digits normalized](docs/digits.png)

## License

MIT. See [LICENSE](LICENSE).
