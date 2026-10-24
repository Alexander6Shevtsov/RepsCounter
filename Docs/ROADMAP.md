# Development plan

Status: **In Development**. Milestone durations are rough engineering estimates, not delivery promises.

| Milestone | Output | Acceptance criteria |
|---|---|---|
| M0: project setup | Xcode target, repo metadata, README, tests | Opens and builds in Xcode 26, runs on iOS 17+ device |
| M1: camera | Live rear-camera preview and permission UI | No UI freezes; permission denial handled; orientation verified |
| M2: pose | On-device Vision joints and skeleton overlay | Skeleton follows visible joints; coordinate mapping checked on real hardware |
| M3: squat counting | Angle smoothing and FSM | Full squat increments once; partial squat does not; missing joints do not create counts |
| M4: workout flow | Sets, pause, rest, finish, Core Data history | Sessions save/reopen; partial sessions and errors handled |
| M5: quality | Unit + recorded-fixture tests, manual field testing, accessibility | Repeatability benchmark; no obvious UI clipping; no critical device crashes |
| M6: expansion | Push-ups, settings, charts, plans | Separate exercise analyzers and tested configuration |

## Manual test matrix

- iPhone in portrait: bright and dim light; plain/busy background.
- Side-view squats: slow/fast cadence; partial squat; full squat; standing still.
- Unreliable detection: knee or ankle hidden, person leaves frame, two people in frame.
- Lifecycle: permission denied, permission changed in Settings, foreground/background, call interruption.
- User state: pause mid-squat, finish during rest, relaunch and load workout history.
- Performance: 10-minute session on device; check dropped frames, memory, battery and thermal behaviour.

## Test infrastructure planned

- XCTest for geometry and counter.
- Deterministic synthetic angle streams for threshold jitter and temporary occlusion.
- Recorded test videos with manually labelled repetitions, processed locally for validation.
- Comparison metric: absolute count error per clip, false positives, false negatives, and frame-processing latency. A numeric accuracy claim is inappropriate until this dataset has been measured.
