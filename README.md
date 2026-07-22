# Audience Wonderland Text Orientation

Detect the angle a person wrote at on an impression pad, and return the strokes rotated
upright, ready to feed a recognizer such as MyScript iink. It handles any angle, tall or
short letters, cursive, all caps, and multiple lines, in a single geometric pass. No
recognition search.

## The headline: this is not the four-directions approach

It does **not** run recognition in several orientations and pick the best. It detects the
write angle once, with pure geometry on the strokes and no recognition, rotates the strokes
upright once, and recognizes once. Think of the four-directions method as trying four keys in
a lock where each try is a full recognition pass. This reads the shape of the lock and cuts
the exact key one time. An answer of 47 degrees costs the same as 90 degrees, because it is a
formula, not a search.

**Cost, measured.** Detection is about 0.2 ms on a 1200-point sample (unoptimized; Swift is
faster) and triggers zero recognition passes. Recognition then runs once, and a second time
only when confidence is low. On a real test that was one pass for 12 of 13 samples versus four
passes every time. It reduces the expensive work rather than adding to it.

## How it works

1. **Baseline from stroke centroids.** Take the center of each stroke. The center of a tall
   vertical stroke sits at its middle, on the text midline, so across letters the centroids
   line up along the baseline no matter how tall the letters are. A 2D PCA of those centroids
   gives the baseline angle. Using centroids, not the raw ink bounding box, is what makes it
   immune to tall narrow writing where the ink is taller than it is wide.

2. **Pick the right rotation by reading structure.** The baseline axis leaves four possible
   rotations. Score each for how much it reads like text: horizontal lines, reading left to
   right in time within a line, and lines stacked top to bottom in time. The winner is the
   orientation. Because line order in time tells you which end is up, this resolves upright vs
   upside down and handles multiple lines in one step, including short stacked words.

3. **"Start is up" prior.** People begin a glyph near its top (a 6 and a 9 both start at the
   top). That prior breaks ties, and for a lone digit or letter, where there is no baseline to
   work from, it drives a dedicated single-glyph path: keep the glyph tall and put the first
   written point at the top. This is how a lone 6 written on a flipped pad, which looks like a
   9, comes back as an upright 6.

4. **Confidence is the winning margin.** How far the best orientation beats the runner-up is
   the confidence. Clean input wins clearly and reports high confidence. Ambiguous input
   reports low confidence, which is the signal to verify with a second recognition pass.

## Tested (on a Lumen Trilogy pad)

- **Arbitrary angles:** an exact rotation sweep at every 10 degrees, 180 of 180 correct, worst
  case 2 degrees, zero upside-down flips. Continuous, so there is no bad angle.
- **Tall / long / narrow letters:** handled (centroid baseline).
- **Print, cursive, all caps, mixed:** 12 varied words at random angles, all upright.
- **Multiple lines:** a four-word block detected as separate lines and oriented; short stacked
  words handled by line order. No regressions on single-line words.
- **Single digits (6 vs 9):** on natural writing, lone 6s and 9s at varied orientations all
  came back upright via the start-is-up prior, including 6s that arrived looking like 9s.
- **Underlines / box edges:** long near-straight strokes are dropped before the baseline fit.

**Honest limits.** Very messy, overlapping writing can leave a few degrees of residual tilt.
A single digit written in an unusual stroke order (not starting at the top) can still be
oriented wrong; the start-is-up prior is a strong aid, not a guarantee, so lean on the
confidence flag and context for lone glyphs. Multi-digit numbers are unambiguous because the
digits form a baseline and a reading direction.

## Usage

```swift
let result = TextOrientation.detect(strokes)      // result.degrees, .confidence, .lineCount
let upright = TextOrientation.normalize(strokes)  // strokes rotated upright

// Feed MyScript. Nothing in your recognition pipeline changes:
let events = TextOrientation.myScriptPointerEvents(strokes)   // (x, y, t) pointer events
let text = myScript.recognize(events)

// Confidence-gated fallback (never worse than four-way, usually one pass).
// On rare low-confidence input, run the two candidates in PARALLEL and keep the higher-scoring
// one, so even the fallback costs one pass of latency:
if result.confidence < 0.35 {
    let flipped = TextOrientation.apply(TextOrientation.normalize(strokes), rotation: .pi)
    // recognize `flipped` concurrently; keep the better result.
}
```

`Stroke` is `[StrokePoint]`; `StrokePoint` is `(x, y)`. Pressure and timestamps are not
required. Feed strokes in the order they were written; each pen-up ends a stroke.

## Notes and next steps

- **Latency on stage.** Estimate orientation incrementally as strokes arrive, so it is already
  locked when the pen lifts. And on low-confidence input, recognize the two candidate
  orientations in parallel.
- **Content constraint (idea, not built).** When the routine implies a category (a city, a
  name, a number), a restricted MyScript lexicon raises accuracy and resolves orientation
  almost for free, since only the correct orientation yields a valid word.
- **Non-text and palm marks.** Use the pad's pressure to reject spurious marks and to segment
  strokes more cleanly than time gaps.
- **Residual-tilt refinement (future).** For very messy diagonal writing, refit the baseline
  within each detected line after the first pass.

## Examples

Twelve varied words written at random orientations, all normalized upright:

![words before and after](docs/words-before-after.png)

Lone digits (6 and 9) at varied orientations, recovered upright by the start-is-up prior:

![digits normalized](docs/digits.png)

## License

MIT. See [LICENSE](LICENSE).
