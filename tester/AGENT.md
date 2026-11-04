# Instructions for an AI agent (Claude Code, Codex, or similar)

You are helping Mark at Audience Wonderland test the auto text orientation in this repo on his own Lumen impression pad. Your job: get the tester running, guide him through writing on the pad, and after every impression tell him what angle it was turned, how long the turn took, and what the handwriting says. He is not a developer, so talk in plain language and keep it short.

## 1. Set up

- This needs macOS with Bluetooth. If you're not on a Mac, stop and tell him so.
- If the repo isn't cloned yet: `git clone https://github.com/chrismikemagic/audience-wonderland-text-orientation.git` and `cd` into it.
- Check the Swift compiler: `xcrun --find swiftc`. If it's missing, ask him to run `xcode-select --install` and click Install, then continue once it finishes.
- Check the install with the bundled sample (no pad needed):

      tester/run.sh --replay sample --no-open

  It should build (about 30 seconds the first time), then print 7 impressions and a SESSION SUMMARY. If the build fails, show him the error and fix it if you can.

## 2. Run it live

- Ask him to switch the pad on and close IMPRA on his phone and iPad (the pad only connects to one device at a time).
- Start the tester as a long-running background process so you can read its output while it keeps running:

      tester/run.sh

  It needs Bluetooth and, with `--claude`, network access. If your environment sandboxes commands, run it outside the sandbox or ask him to approve that.
- The first time, macOS asks whether the app running this command (Terminal, Claude, Codex...) may use Bluetooth. Tell him to click Allow. If the output says Bluetooth permission is off, walk him to System Settings, then Privacy & Security, then Bluetooth, switch the app on, and restart the tester.
- When the output says READY, tell him to write something on the pad at any angle and stop for a second. Each impression prints a block starting `=== IMPRESSION #n` and saves files in the session folder printed at the top (default `~/Desktop/Lumen Test Results/session-<time>/`).
- If it sits on "Looking for a Lumen pad" for more than 30 seconds, the pad is off or another device has it.

## 3. After every impression, report to him

1. **The orientation.** The hybrid line is the main result: the angle it turned, whether it was sure, and the milliseconds. Also give the geometry-only time for comparison.
2. **Look at the pictures yourself.** Open `impNN.png` (before and after side by side) and check that the right side really is upright and readable. If it's still sideways, upside down, or noticeably tilted, say so plainly. That's a miss, and he should hear about it.
3. **Read the handwriting.** Look at `impNN-upright.png` and say what it says. Compare with the "Apple reads" line (Apple's on-device reader, weak on handwriting) and the "Claude reads" line if it was run with `--claude`. Your own read of the upright picture counts as the AI read, so no API key is needed.
4. Ask him what he actually wrote, and keep a running tally of orientation right versus wrong, and read right versus wrong.

## 4. When he's done

Stop the tester with Ctrl-C (send SIGINT to the process). It prints a SESSION SUMMARY with median and slowest timings. Give him:

- How many impressions, how many the orientation got right, the median and slowest hybrid time, and the geometry-only time.
- How the reading went (yours, Apple's, Claude's if used).
- Where the session folder is. `results.csv` has every number, and the folder can be sent to Chris as is. `raw.log` lets anyone replay the session exactly with `tester/run.sh --replay <path>/raw.log`.

## Useful flags

- `--claude` runs Claude on every impression too (needs `ANTHROPIC_API_KEY` in the environment). Default model `claude-fable-5-1`; change it with `--model`.
- `--gap 0.5` closes an impression after half a second of pen silence instead of one second.
- `--name Stage` connects only to a pad whose name contains that text, if more than one pad is on.
- `--no-open` stops the before/after picture from popping open every time.

Don't modify `TextOrientation.swift` or `VisionTextOrientation.swift`. They're the code under test.
