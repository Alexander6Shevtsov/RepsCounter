# Architecture Decision Record — RepsCounter v0.1

**Status:** In Development

## 1. Decision

Use UIKit + MVVM, with isolated domain logic and constructor injection. Do not introduce VIPER until project complexity justifies more layers. Vision remains a replaceable infrastructure detail rather than being coupled to repetition counting.

## 2. Dependencies

```text
SceneDelegate (composition root for the window scene)
  ├── WorkoutViewController (UIKit, pose overlay)
  │     └── WorkoutViewModel (session state and UI state)
  │            ├── PoseAnalyzer (knee-angle extraction, smoothing)
  │            ├── SquatCounter (pure finite-state machine)
  │            └── WorkoutStoring (Domain contract)
  └── CameraService (AVFoundation)
        └── PoseDetector (Vision)
```

`WorkoutPersistence` implements the MainActor-isolated `WorkoutStoring` contract and is injected through the existing composition root. ViewModel and controllers receive the contract; camera and pose-analysis dependencies remain concrete. `WorkoutSummary` is a value type in Domain with a stable UUID. Mock storage and a controlled Core Data commit operation cover persistence failures without introducing a generic repository framework.

`AppDelegate` remains the process entry point. The static `UIApplicationSceneManifest` in `RepsCounter/App/Info.plist` registers `UIWindowScene` and `SceneDelegate` for the application role; multiple simultaneous scenes are disabled. UIKit creates the scene and calls `scene(_:willConnectTo:options:)`. The scene delegate creates and retains `UIWindow(windowScene:)`, assembles the existing dependencies and presents `WorkoutViewController` with the existing dark appearance.

There are no storyboard keys. Portrait orientation is declared in the same plist for iOS 17 and later. Xcode merges that file with the existing generated bundle metadata and camera permission description in both Debug and Release. This follows Apple's [scene lifecycle migration guidance](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle).

`SceneLifecycleTests` verifies the built app's manifest and the window connected by UIKit, including its scene delegate, root controller, visibility and appearance. Camera interruptions and workout state changes remain separate audit tasks.

## 3. Threading and concurrency

- Session configuration and `startRunning` are dispatched away from the main thread.
- `AVCaptureVideoDataOutput` invokes its delegate on a dedicated serial frame queue.
- Vision inference runs on that queue and is throttled to ~12 frames per second; frames arriving sooner are skipped.
- `WorkoutViewModel` is MainActor-isolated; updates and drawing are dispatched to the main thread.
- Permission handling and camera startup use `async/await`.
- Core Data operations are synchronous on MainActor, using a fresh main-queue context for each save/read. Failed writes roll back and discard that context; history reads committed data only. No managed objects cross the service boundary.

## 4. Squat detection

Camera: rear-facing, vertical iPhone, 2D sagittal/side angle.

Use visible hip, knee and ankle joint landmarks. Require confidence >= 0.5 on all three landmarks. Compute knee angle with the dot-product formula and clamp the cosine to [-1,1]. Smooth with exponential moving average alpha = 0.35.

Finite-state machine:

```text
SEEKING_STANDING --3 frames angle >=160--> STANDING
STANDING         --3 frames angle <=105--> LOWERED
LOWERED          --3 frames angle >=160--> STANDING + 1 repetition
```

Angles between thresholds do not transition the machine. Missing joints suspend counting and, after 12 missed observations, force re-acquisition of a standing posture. Thresholds and stability rules are prototype-only and need calibration with data.

## 5. Frame orientation and overlay alignment

The detector uses `.right` orientation to interpret the rear camera's sensor stream as portrait. Vision reports normalized points with a lower-left origin; the overlay converts those to the unrotated capture-device coordinate system before calling AVFoundation's `layerPointConverted(fromCaptureDevicePoint:)`. Both camera preview rotation and overlay mapping **must be verified on real device hardware**. Format selection, mirroring and camera position changes require synchronized updates.

## 6. Data schema

Workout: `id: UUID?`, `date: Date`, `duration: Int64`, `repetitions: Int64`, `sets: Int64`. New summaries always have a UUID. The stored attribute is optional to allow migration from the initial schema, then a transaction assigns stable UUIDs to legacy rows.

A single Core Data store contains small session summaries. No video files, pose time series, usernames or cloud data are persisted. The exact legacy model is retained; compatible old SQLite stores migrate through an inferred mapping into a temporary store and are replaced using Core Data APIs. Unknown models and damaged stores produce errors without deleting user data.

The finished workout snapshot is retained separately from `.notSaved`, `.saving`, `.saved` and `.failed` persistence states. All retries reuse the snapshot UUID and fields. The storage checks that identifier before inserting, making retries idempotent within the current single-process app, including after reopening SQLite. See [persistence guarantees and limits](PERSISTENCE.md).

## 7. Known MVP limitations

- No adaptive thresholds or height/calibration flow.
- No push-up recognition or multi-person tracking.
- No background workout mode; foreground camera only.
- Confidence threshold is heuristic and the first sufficiently visible leg is selected.
- Temporary camera occlusion can invalidate a partially completed squat.
- Camera/overlay transform and sensor thermal performance are unverified.
- Unit tests cover pure counting logic but no automated video-fixture integration tests yet.
