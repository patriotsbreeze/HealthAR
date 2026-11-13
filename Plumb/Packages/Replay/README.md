# PlumbReplay

Record on the phone, replay and score on the Mac.

A trace holds what the phone's height estimator read from each camera frame: the lens values, the
pose, the hands' pixel, a small LiDAR depth patch over the hands and one beside them, and a 32 by 96
brightness grid over the hands box. No video and no faces. `plumb-replay` runs those frames through
the same `HeightEstimator` and `CompressionAnalyzer` the app runs, prints every push it counted and
a summary, and scores them against a rig's known travel and rate.

This is for checking a training simulator against a rig. Nobody compresses a real person.

## 1. Record

On the show-working screen, press **Record measurements**, push on the rig, press **Stop recording**.
The app writes `plumb-trace-YYYYMMDD-HHMMSS-mmmZ.jsonl` to its Documents folder. Twenty seconds is
about 6 MB. A recording the app was killed in the middle of still opens: only the cut-off last line is lost.

Write down what you did: the travel the rig allows (a stop or spacer, in mm), the metronome rate,
the distance and the angle of the phone.

## 2. Pull the traces off the phone

The app's Info.plist needs both of these, set to YES. `project.yml` and `App/Info.plist` already have them.

| Key | Why |
| --- | --- |
| `UIFileSharingEnabled` | The Documents folder shows in Finder when the phone is plugged in. |
| `LSSupportsOpeningDocumentsInPlace` | The same folder shows in the Files app under On My iPhone, Plumb. |

Then any of:

- **Finder:** plug the phone in, select it in the sidebar, open the Files tab, open Plumb and drag the
  `.jsonl` files out.
- **Files app:** On My iPhone, Plumb, select the files, Share, AirDrop to the Mac.
- **Terminal** (Xcode 15 or later; find the device with `xcrun devicectl list devices`):

  ```sh
  xcrun devicectl device copy from --device <device id> \
    --domain-type appDataContainer --domain-identifier com.patriotsbreeze.Plumb \
    --source Documents --destination recordings
  ```

Keep them in `recordings/` at the top of the repository, which git ignores.

## 3. Replay

```sh
cd Packages/Replay
swift run -c release plumb-replay ../../recordings/plumb-trace-20261112-140322-123Z.jsonl \
  --truth-depth-mm 50 --truth-rate 110
```

| Flag | Does |
| --- | --- |
| `--method alongRay` or `imagePlane` | Height method. Default `alongRay`, as the app runs. |
| `--truth-depth-mm <mm>` | The rig's travel per push. Scores depth: n, median absolute error, bias, lowest and highest error. |
| `--truth-rate <per minute>` | The rate pushed at. Scores the rate each interval implies. |
| `--fit-gain` | Fits a gain that puts the median locked depth on the truth, prints it, and scores nothing. |
| `--gain <value>` | Multiplies every height by the gain before the analyzer. |
| `--gain-from <trace>` | Fits the gain on that trace, then scores this one with it. Refuses when both are the same recording, by content, whatever the file names. |
| `--no-range` | Takes LiDAR away (see below) and prints that run next to the app's own along-ray LiDAR run of the same frames, which gets no gain. |
| `--assume-range-m <m>` | The distance assumed with `--no-range`. Default 1.0, the distance the capture defaults are tuned for. |
| `--csv <path>` | One line per push: run, index, bottom time, depth, interval, trust, time reported. Refuses a path that is one of the traces it reads. |

Depth is scored twice: on locked pushes, the only ones the coach judges, and on all of them.
"Delay to report" is trace time from a push's deepest point to the sample that revealed it; the
phone's own processing comes on top.

### Calibrate on one recording, score on another

A gain is never scored on the recording it was fitted on. Fit on A, score B:

```sh
swift run -c release plumb-replay A.jsonl --truth-depth-mm 50 --fit-gain
swift run -c release plumb-replay B.jsonl --truth-depth-mm 50 --gain 1.043
# or both at once, with the check that A and B differ:
swift run -c release plumb-replay B.jsonl --truth-depth-mm 50 --gain-from A.jsonl
```

### What LiDAR is worth

Neither height method can run with the range unknown. Along the line of sight the height *is* the
LiDAR range. The picture slide needs the range to turn pixels into millimetres. So `--no-range`
runs the closest honest variant: the picture slide with every LiDAR reading replaced. Each frame's
hands depth patch becomes a flat patch at the assumed distance along the line of sight through the
hands, and the still reference patch is dropped. Pose, lens values, the hands' pixel and the
brightness grid stay as recorded. That is kind to the camera-only case, because on a LiDAR phone
ARKit's tracking may lean on depth, and the hands box was placed using depth.

A wrong guess scales every depth by guess over true distance. A gain can hide that at one distance
but not at another. In the tests, a camera-only gain fitted at 0.9 m reads the same 50 mm about
45 percent deep at 0.6 m. The along-ray LiDAR run needs no gain at either distance.

## How the replay differs from the phone

- The phone's estimator may have been running before the recording began. The replay starts fresh
  at the first recorded frame, so the first second or two can differ. Heights are relative, so
  after that only a constant offset remains.
- The phone ticks the analyzer on a ten-a-second wall-clock timer. The replay ticks on an even beat
  of trace time, which can move when a pause or a loss of signal is noticed, by less than a tick.
- The phone restarts its estimator whenever the hands box is placed again. A trace does not say so,
  but each placement lays a new brightness grid with a new row spacing. The replay restarts on that
  and reports how many times it happened.

## Found on the synthetic rig

The tests render a propped camera looking down 40 degrees at a textured plate that travels exactly
50 mm. Along the line of sight, the replay gets every push within 2 mm and the rate within 1 a
minute. The picture slide counts the same pushes but reads about 7 percent short at 50 mm. The phone
passes the estimator the fixed pixel of the box centre, and the estimator converts the slide as if
that pixel followed the hands down. Moving the pixel with the plate in the rig removes the shortfall.

Run the tests with `swift test` in this folder.
