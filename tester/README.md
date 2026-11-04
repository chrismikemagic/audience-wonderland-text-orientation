# LumenTest: try the auto orientation on your own pad

Mark, this is the hands-on version of everything in the main README. You connect your Lumen pad to your Mac, write on it at any angle you want, and every time you pause it shows you the ink as you wrote it next to the ink after the code turns it upright. It tells you exactly how long the turn took, and then it reads the text so you can see whether recognition works on the result.

You don't need to trust my numbers. Try it with the nastiest handwriting you can come up with, upside down, sideways, diagonal, two lines, cursive, whatever, and watch what it does.

## What you need

- A Mac with Bluetooth (any Mac from the last several years is fine).
- Your Lumen pad, switched on.
- IMPRA closed on your phone and iPad, or Bluetooth off on them for the test. The pad only talks to one device at a time, so if IMPRA grabs it first the Mac can't see it.
- Apple's free developer tools. If you've never installed them, the script tells you how (it's one command and a click).

## The easy way: let your AI do it

If you use Claude Code or Codex, just paste this to it:

    Clone https://github.com/chrismikemagic/audience-wonderland-text-orientation and follow tester/AGENT.md to help me test my Lumen pad.

It will set everything up, run the test, and read each impression for you as you go. The instructions it follows are in [AGENT.md](AGENT.md).

## Doing it yourself in Terminal

Open Terminal (Command + Space, type Terminal) and paste these one at a time:

    git clone https://github.com/chrismikemagic/audience-wonderland-text-orientation.git
    cd audience-wonderland-text-orientation
    tester/run.sh --replay sample

That last line is a quick check that everything installed. It runs seven impressions I wrote on my Stage through the code, no pad needed, and you'll see a picture pop up for each one. The very first run takes about 30 seconds to build.

Then turn your pad on and run:

    tester/run.sh

The first time, your Mac asks if Terminal can use Bluetooth. Say yes. It finds the pad, says READY, and from then on:

1. Write something on the pad, at any angle.
2. Stop writing. After one second of no pen, it processes what you wrote.
3. A picture opens: as written on the left, turned upright on the right, with the timing and what was read underneath.
4. Write the next one. When you're done, press Control + C and you get a summary of all the timings.

## What the numbers mean

For every impression you see something like this:

    === IMPRESSION #3  (4 strokes, 236 points) ===
      Orientation (hybrid, recommended):  209.2 deg  confidence 1.00  sure  45 ms
      Orientation (geometry only):        208.7 deg  confidence 1.00  sure  0.05 ms
      Apple reads (on-device):  "marmęś"  conf 1.00  40 ms
      Claude reads (claude-fable-5-1): "Mark"  998 ms

- **Hybrid** is the one I recommend shipping. It does the fast geometry first, then lets Apple's on-device text engine double check it and straighten out any leftover tilt. It usually takes 30 to 200 milliseconds.
- **Geometry only** is the pure math version, with no Apple at all. It's a fraction of a millisecond, and it's the version that would also run on Android.
- **Confidence** goes from 0 to 1. When it says UNSURE, that's the code telling you "I genuinely can't tell which way this is," which is your app's cue to fall back to a second try instead of guessing wrong.
- **The time** is measured from the moment the impression closes. On a live pad, add the one second of pen silence the tester waits for to decide you've stopped writing. That wait is a setting in the tester, not part of the orientation, and you can change it with `--gap 0.5`.

## Reading the text

Turning the ink upright is the job this code does. The reading is there so you can see that the result is actually readable. You get three options, and you can use any of them:

1. **Apple's on-device reader** runs every time, free and offline. Fair warning: Apple is pretty weak on handwriting (you already found that when you tested it), so treat its read as a rough check, not the final answer. In the example above it read "marmęś" for "Mark."
2. **Claude** reads it far better. In the same example it got "Mark" in about a second. To turn it on you need an Anthropic API key (from console.anthropic.com), then:

       export ANTHROPIC_API_KEY=your-key-here
       tester/run.sh --claude

   It uses Claude Fable 5.1 by default, which was the fastest and most accurate in my tests. You can pick another model with `--model`.
3. **Your own AI.** Every impression also saves a clean upright picture (`imp03-upright.png`). If you're running this through Claude Code or Codex, it can just look at that picture and tell you what it says, no API key needed.

And for Shamir: every impression also saves the upright strokes as JSON, so he can feed the exact same ink straight into MyScript and compare.

## Where everything is saved

Each run makes its own folder in `Lumen Test Results` on your Desktop:

- `imp01.png`, `imp02.png`... the before and after pictures
- `imp01-upright.png`... the clean upright ink, good for any AI or recognizer
- `imp01.json`... the strokes as written and upright, plus every number
- `results.csv`... one row per impression with all the timings and reads; opens in Numbers or Excel
- `raw.log`... the raw pad data, so any session can be replayed later with `tester/run.sh --replay path/to/raw.log`

If something weird happens, send me that session folder and I can replay exactly what you wrote.

## Options

    tester/run.sh --help

    --gap SECONDS     pen silence that ends an impression (default 1.0)
    --name TEXT       only connect to a pad whose name contains TEXT, like Stage
    --out FOLDER      save results somewhere other than the Desktop
    --claude          also have Claude read each impression
    --model ID        which Claude model to use
    --no-open         don't pop open a picture for every impression
    --replay FILE     re-run a saved raw.log, no pad needed

## If something goes wrong

- **It never finds the pad.** Make sure the pad is on and IMPRA isn't connected to it on another device. Turn the pad off and on again and rerun.
- **It says Bluetooth permission is off.** Open System Settings, then Privacy & Security, then Bluetooth, and switch on Terminal (or whichever app you ran it from). Then run it again.
- **It says it needs developer tools.** Run `xcode-select --install`, click Install, wait for it to finish, and run again.
