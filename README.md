# RepsCounter

**Status: In Development** · iOS 17+ · Swift · UIKit · Vision · AVFoundation

RepsCounter is an iOS exercise tracker designed to count repetitions using on-device human pose estimation. The camera stream is processed locally; the app does not upload or save workout video.

> **Development status:** This repository contains an initial implementation scaffold. The design image below is a **UI concept, not a screenshot of running software**. Features and accuracy require verification on a real iPhone before they can be claimed as production-ready.

## Technical audit — 24 October 2026

The unchanged starter is preserved in the first commit and the `starter-v0.1.0` tag. See the [technical audit in Russian](Docs/TECHNICAL_AUDIT.md), [prioritized next tasks](Docs/NEXT_TASKS.md), and [baseline file checksums](Docs/BASELINE_MANIFEST.json).

- Xcode 27.1 / Swift 6.4, project Swift language mode 5: Debug Simulator and unsigned Release device builds succeeded.
- Existing XCTest on iOS Simulator 18.6: **8 passed, 0 failures**.
- The starter host app failed to launch on iOS Simulator 27.0 with SDK 27.1 because it did not adopt the required `UIScene` lifecycle. This is addressed by the A01 fix below.
- The starter reported camera isolation issues and failed a Swift 6 diagnostic build. The A02/A06 changes below address this; project language settings remain unchanged.
- Xcode 26, iOS 17 runtime, physical camera, tracking accuracy and accessibility have not been validated.

## A01 fix — scene lifecycle

The `fix/scene-lifecycle` branch moves the existing window and dependency assembly into `SceneDelegate`. The static `RepsCounter/App/Info.plist` registers one programmatic window scene and preserves portrait orientation, dark appearance and iOS 17 deployment support. UIKit, MVVM, the workout algorithm, Core Data and the workout interface are unchanged.

Validation with Xcode 27.1 / SDK 27.1:

- Debug Simulator and unsigned Release device builds succeeded.
- All **10 XCTest passed on iOS Simulator 27.0 and 18.6**: the original 8 tests plus 2 regressions for the built scene manifest and the actual connected workout window.
- The app was also launched separately on iPhone 18 Pro Max / iOS Simulator 27.0; the workout screen appeared. The simulator reported that the rear camera was unavailable.
- Debug and Release built plists were checked for scene registration, no storyboard keys, portrait, iOS 17.0, camera permission text and dark appearance.
- An iOS 17 runtime is unavailable, so runtime compatibility with iOS 17 remains unverified. Existing camera concurrency and accessibility audit findings remain open.

The A01 fix was merged through [PR #1](https://github.com/Alexander6Shevtsov/RepsCounter/pull/1). Status remains **In Development**.

## Workout persistence — A03, A04, A09

The persistence changes merged through [PR #2](https://github.com/Alexander6Shevtsov/RepsCounter/pull/2) into `main` (`6c9474b`) separate finishing a workout from saving its result. A failed save keeps the frozen summary available for retry; success is shown only after the storage confirms it. Stable UUIDs, isolated transactional contexts and a committed-only history prevent duplicate retries and unsaved history entries.

The small MainActor-isolated `WorkoutStoring` contract allows controlled failure tests. The original SQLite schema migrates to an optional UUID attribute and stable identifiers are assigned to old rows. Existing workout fields and the default store path are preserved. See [the persistence design, migration and limits](Docs/PERSISTENCE.md).

Validation with Xcode 27.1 / SDK 27.1 on the PR source: Debug with complete strict concurrency and unsigned Release builds succeeded; **29 XCTest passed on both iOS Simulator 27.0 and 18.6**. The suite includes legacy SQLite migration, failure/retry, idempotency and the existing scene regressions. Remaining concurrency diagnostics concern the existing camera implementation. A separate manual iOS 27 check confirmed the success message after saving and the corresponding history entry.

An unsaved result is retained for the current process lifetime; recovery of an unsaved draft after force quitting is not implemented. Multi-process writers are not supported. Stage 3 preserved camera, counting, rest timing, screen layout and Swift language mode.

## Workout timing and pause — A05, A10 — 25 October 2026

The timing changes merged through [PR #3](https://github.com/Alexander6Shevtsov/RepsCounter/pull/3) into `main` (`a134e81`). Workout duration includes rest and excludes explicit pauses. A `ContinuousClock` source measures elapsed time independently of changes to the system date; `Date` supplies the workout's start timestamp. Rest uses the same active-time scale, so both elapsed time and remaining rest freeze during a pause.

Pausing resets the unfinished movement and pose smoothing while preserving completed repetitions. After resuming, standing must be confirmed again before a new squat can count. A cancellable task replaces the repeating timer and is cancelled on pause, finish and model release. The finished summary retains the stable UUID and unchanged fields across save retries. The set count includes completed sets plus a current partial set containing at least one repetition.

Validation with Xcode 27.1 / SDK 27.1: Debug with complete strict concurrency and unsigned Release builds succeeded; **54 XCTest passed on both iOS Simulator 27.0 and 18.6**. The additions are 19 deterministic timing tests and 6 movement-reset tests. They cover fractional time, 60-second rest, pause/resume, fresh standing confirmation, rapid Pause → Resume → Finish, frozen retry summaries and set counts without real waits. Existing storage, UUID and scene regressions pass. Remaining diagnostics concern the existing camera implementation and deprecated button API.

Core Data, its schema, camera handling and the interface were unchanged by that stage. Automatic pausing is addressed in stage 5 below; physical-device validation and an iOS 17 runtime remain unavailable. See [architecture and timing semantics](Docs/ARCHITECTURE.md).

## Camera lifecycle and concurrency — A02, A06 — 25 October 2026

The `fix/camera-lifecycle` branch starts from merged PR #3 (`main`, `a134e81`). A capture actor owns session configuration/start/stop on one serial executor outside MainActor. Vision stays on a separate serial frame queue; generation and age checks prevent stopped or stale results from reaching the workout. Narrow permission/capture contracts allow tests without physical camera access.

The workout waits for camera readiness before active time begins. Backgrounding, interruptions and runtime errors pause it without losing completed repetitions, rest or duration. Returning from Settings/foreground or ending an interruption requires an explicit **Продолжить**. Pending starts are cancelled on stop/finish, and retries preserve the existing frozen UUID summary. The interface uses its existing guidance label for Russian camera errors and the existing button for retry.

Debug Simulator and unsigned Release device builds with complete strict concurrency succeeded. A separate Swift 6 `build-for-testing` also succeeded without changing project language mode 5. **90 XCTest passed on each available iOS Simulator version: 18.6, 26.5, 27.0 and 27.1** (54 existing + 36 new). Camera components and new tests have no concurrency warnings. Remaining diagnostics concern the existing deprecated button API and an unchanged Core Data test in the Swift 6 diagnostic compilation.

One small `@unchecked Sendable` preview bridge is explicitly justified: it hides an immutable session reference and only attaches the UIKit preview on MainActor before startup; the actor exclusively controls session operations. See [concurrency rationale, cancellation limits and iPhone checklist](Docs/CAMERA_LIFECYCLE.md). Core Data/schema, counting and Vision algorithms, deployment target and dependencies are unchanged. Hardware camera, iOS 17 runtime, tracking accuracy and performance remain unverified. Those changes merged through [PR #4](https://github.com/Alexander6Shevtsov/RepsCounter/pull/4). PR #5 subsequently updated file headers and button configuration. Status remains **In Development**.

## Front and rear camera switching — 27 October 2026

The `feature/camera-switching` branch starts from `main` after PR #5 (`6c2b82d`). The workout starts with the front camera. The top-right `arrow.triangle.2.circlepath.camera` button switches front → back → front in the existing capture session. Repeated taps during an operation are ignored. Switching freezes active time/rest and clears only unfinished movement; counted repetitions, sets and the frozen save/retry summary are preserved. An active workout resumes after successful camera readiness, while a paused workout stays paused. Backgrounding, interruption or failure cancels automatic continuation.

Capture and preview use the selected sensor's actual portrait rotation. Vision receives upright, unmirrored buffers; only the front preview is mirrored. Pose values carry the actual rotation, and overlay conversion delegates mirroring/aspect fill to AVFoundation once. On iOS 17–26, a narrow legacy portrait compatibility helper is required to obtain the device-specific angle; iOS 27 uses the static RotationCoordinator API. Its intentional deprecation warning and the reason a fixed 90° angle is insufficient are documented in [camera lifecycle and switching](Docs/CAMERA_LIFECYCLE.md).

Debug/unsigned Release builds and a Swift 6 diagnostic build-for-testing succeeded with Xcode 27.1 / SDK 27.1. All **133 XCTest passed on each iOS Simulator 18.6, 26.5, 27.0 and 27.1**: 90 existing plus 26 switching/state/UIKit and 17 geometry tests. XCTest execution used project Swift language mode 5. The new tests cover switching, timing, repetition preservation, interruptions, cancellation, UIKit controls and geometry. Physical switching, Vision alignment and performance still require the [iPhone 15 Pro checklist](Docs/CAMERA_LIFECYCLE.md#проверка-pr6-на-iphone-15-pro). No physical-device success is claimed. Status remains **In Development**; the branch awaits review.

![RepsCounter interface — design concept, not a working application screenshot](Docs/Concept.png)

## MVP scope

- [x] Initial Xcode project structure and UIKit app entry point
- [x] AVFoundation rear-camera capture implementation
- [x] Vision-based 2D body joint detection implementation
- [x] Skeleton overlay and squat-angle calculations
- [x] Squat repetition state machine with threshold hysteresis and test cases
- [x] Basic sets, rest countdown, pause/finish and locally persisted history
- [ ] Build verified in Xcode 26 and on a physical iPhone
- [ ] Camera-preview / skeleton coordinate alignment verified on hardware
- [ ] Rep-counting accuracy benchmarked against labelled workout recordings
- [ ] Accessibility and performance validation complete

The checkboxes above mean **source code has been implemented**, not that the corresponding behaviour has been validated on a device.

## Why this project?

The main engineering challenge is translating noisy, low-confidence 2D joint measurements into stable, testable exercise events without counting incomplete movements twice.

## Technology

| Area | Technology |
|---|---|
| UI | UIKit, Auto Layout, Dynamic Type (initial support) |
| Camera | AVFoundation, `AVCaptureVideoDataOutput` |
| Pose estimation | Vision, `VNDetectHumanBodyPoseRequest` |
| Domain logic | Joint-angle geometry, exponential smoothing, finite-state machine |
| Persistence | Core Data, programmatic data model |
| Concurrency | MainActor state; capture actor with serial executor; serial Vision queue and bounded pose stream |
| Testing | XCTest for geometry, counting, timing, persistence, camera lifecycle and scene regressions |
| Architecture | MVVM + lightweight Clean Architecture + constructor injection |

## How counting works

1. Camera produces frames, throttled for Vision processing to around 12 FPS.
2. Vision returns a set of joint points with confidence values.
3. Geometry computes the knee angle from hip, knee, and ankle (side view).
4. Exponential smoothing stabilizes the angle estimate.
5. The deterministic counter transitions: `seekingStanding` → `standing` → `lowered` → `standing`.
6. Only the last transition counts one complete repetition.

Prototype thresholds: standing ≥160°, lowered ≤105°, with 3 consecutive frames per phase. The thresholds are **initial assumptions**, not validated biomechanical criteria. After 12 missing-pose samples, the state machine requires reacquiring standing position.

## Run locally

1. Download the repository and open `RepsCounter.xcodeproj` in Xcode 27.1 (the verified SDK/toolchain; deployment target remains iOS 17).
2. Select the **RepsCounter** scheme and set your Apple Developer team (Signing & Capabilities).
3. Connect an iPhone running iOS 17 or later. The iOS Simulator does not provide the physical camera workflow required for pose tracking.
4. Build and run. Grant camera permission when prompted.
5. Place the iPhone securely, preferably side-on, with shoulders, hips, knees and ankles in frame.
6. Stand upright to initialize recognition; complete a squat and return to standing to count one repetition.

Camera analysis uses a fixed portrait interface, the selected front/rear sensor’s actual rotation and unmirrored Vision input. Front preview mirroring and skeleton alignment still require on-device verification; see the camera lifecycle document.

## Repository layout

```text
RepsCounter.xcodeproj
RepsCounter/
  App/                 AppDelegate, SceneDelegate composition root and scene manifest
  Domain/              Pose, geometry, smoothing, repetition state machine
  Services/            AVFoundation, Vision and Core Data
  Presentation/        UIKit screen, skeleton overlay, MVVM
RepsCounterTests/      XCTest
Docs/                  Design concept, architecture, roadmap, CV text
```

## Privacy

- The camera stream is processed on the device, with no network integration.
- No recorded video is uploaded or retained.
- Core Data stores only workout summary metadata (UUID, start timestamp, duration, repetitions and sets, including a nonempty partial set).
- Permission can be revoked in iOS Settings.

## Roadmap

See [development milestones](Docs/ROADMAP.md) and [architecture notes](Docs/ARCHITECTURE.md). Push-ups, further exercises, training plans, charts, adaptive thresholds and accessibility polishing are **planned**, not yet implemented.

## Design

Visual direction: fullscreen live camera, bright blue pose connections and repetition count, dark translucent controls. The attached concept includes features outside the MVP; visual assets are mockups only.

## Author

[Alexander Shevtsov](https://github.com/Alexander6Shevtsov)

## License

MIT. See [LICENSE](LICENSE).
