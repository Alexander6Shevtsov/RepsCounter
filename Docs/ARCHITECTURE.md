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
  │            └── WorkoutPersistence (Core Data)
  └── CameraService (AVFoundation)
        └── PoseDetector (Vision)
```

Current prototype uses constructor injection for services, not yet fully abstracted protocols. Protocol boundaries and test doubles are a planned refactor.

`AppDelegate` remains the process entry point. The static `UIApplicationSceneManifest` in `RepsCounter/App/Info.plist` registers `UIWindowScene` and `SceneDelegate` for the application role; multiple simultaneous scenes are disabled. UIKit creates the scene and calls `scene(_:willConnectTo:options:)`. The scene delegate creates and retains `UIWindow(windowScene:)`, assembles the existing dependencies and presents `WorkoutViewController` with the existing dark appearance.

There are no storyboard keys. Portrait orientation is declared in the same plist for iOS 17 and later. Xcode merges that file with the existing generated bundle metadata and camera permission description in both Debug and Release. This follows Apple's [scene lifecycle migration guidance](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle).

`SceneLifecycleTests` verifies the built app's manifest and the window connected by UIKit, including its scene delegate, root controller, visibility and appearance. Camera interruptions and workout state changes remain separate audit tasks.

## 3. Threading and concurrency

- Session configuration and `startRunning` are dispatched away from the main thread.
- `AVCaptureVideoDataOutput` invokes its delegate on a dedicated serial frame queue.
- Vision inference runs on that queue and is throttled to ~12 frames per second; frames arriving sooner are skipped.
- `WorkoutViewModel` is MainActor-isolated; updates and drawing are dispatched to the main thread.
- Permission handling and camera startup use `async/await`.
- Core Data access currently occurs on the main context; optimize persistence if storage becomes more complex.

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

Workout: `date: Date`, `duration: Int64`, `repetitions: Int64`, `sets: Int64`.

A single Core Data store contains small session summaries. No video files, pose time series, usernames or cloud data are persisted. Schema versioning and migrations will be needed as exercise types and historical set data are added.

## 7. Known MVP limitations

- No adaptive thresholds or height/calibration flow.
- No push-up recognition or multi-person tracking.
- No background workout mode; foreground camera only.
- Confidence threshold is heuristic and the first sufficiently visible leg is selected.
- Temporary camera occlusion can invalidate a partially completed squat.
- Camera/overlay transform and sensor thermal performance are unverified.
- Unit tests cover pure counting logic but no automated video-fixture integration tests yet.
