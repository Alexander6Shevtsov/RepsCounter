# Architecture Decision Record — RepsCounter v0.1

**Status:** In Development. Updated 25 October 2026. PR #3 timing changes are merged (`main` at `a134e81`); A02/A06 changes are in `fix/camera-lifecycle` awaiting review.

## 1. Decision

Use UIKit + MVVM, with isolated domain logic and constructor injection. Do not introduce VIPER until project complexity justifies more layers. Vision remains a replaceable infrastructure detail rather than being coupled to repetition counting.

## 2. Dependencies

```text
SceneDelegate (window composition and lifecycle forwarding)
  ├── WorkoutViewController (UIKit and pose overlay)
  │     ├── WorkoutCameraCoordinator (MainActor lifecycle agreement)
  │     └── WorkoutViewModel (MainActor workout and UI state)
  │            ├── PoseAnalyzer / SquatCounter
  │            ├── WorkoutTimeSource
  │            └── WorkoutStoring
  └── CameraService (MainActor permission/start state)
        ├── CameraAuthorizing
        └── CameraCapturing
              └── CameraCapture (actor, serial session executor)
                    └── CameraFrameProcessor (serial frame queue)
                          └── PoseDetector (Vision)
```

`WorkoutPersistence` implements the MainActor-isolated `WorkoutStoring` contract. ViewModel and controllers receive that contract through constructor injection. `WorkoutSummary` is a Domain value with a stable UUID. `CameraService` receives two small contracts for permissions and capture; the coordinator receives the service and ViewModel. Mock capture/permission, controlled storage failures and a monotonic clock cover lifecycle behavior without a generic repository or camera framework. Analyzer and counter remain concrete domain components.

`AppDelegate` remains the process entry point. The static `UIApplicationSceneManifest` in `RepsCounter/App/Info.plist` registers `UIWindowScene` and `SceneDelegate` for the application role; multiple simultaneous scenes are disabled. UIKit creates the scene and calls `scene(_:willConnectTo:options:)`. The scene delegate creates and retains `UIWindow(windowScene:)`, assembles the existing dependencies and presents `WorkoutViewController` with the existing dark appearance.

There are no storyboard keys. Portrait orientation is declared in the same plist for iOS 17 and later. Xcode merges that file with the existing generated bundle metadata and camera permission description in both Debug and Release. This follows Apple's [scene lifecycle migration guidance](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle).

`SceneLifecycleTests` verifies the built app's manifest and the window connected by UIKit, including its scene delegate, root controller, visibility and appearance. The scene also forwards background/active/disconnect events to the camera coordinator. Background pauses and stops capture; active refreshes permission without automatically resuming; disconnect permanently releases capture resources for that scene.

## 3. Threading and concurrency

- `CameraCapture` owns all session configuration/start/stop on a custom serial executor, outside MainActor. No suspension occurs inside a configuration/start transaction.
- A separate serial frame delegate owns Vision processing. An `OSAllocatedUnfairLock` confines mutable detector state and serializes invalidation. No raw buffers or Vision objects cross executors.
- Analysis retains the 80 ms interval and AVFoundation late-frame discard. A newest-only pose stream, run generation, monotonic analysis timestamp and 250 ms age limit reject obsolete results at MainActor.
- `CameraService`, the coordinator, ViewModel and UIKit updates are MainActor-isolated. Permission requests and pending starts are coalesced/cancellable; finish is terminal. Session notifications travel separately from frames and are removed on shutdown.
- The only `@unchecked Sendable` type is a private-reference preview bridge. It only attaches the same session to the UIKit layer before start; it exposes no session operations. Full ownership/lock justification and native cancellation limits are recorded in [CAMERA_LIFECYCLE.md](CAMERA_LIFECYCLE.md).
- Core Data operations remain synchronous on MainActor, with a fresh main-queue context per save/read, rollback on failure and committed-only history. Managed objects do not cross the service boundary.
- The existing weakly captured MainActor update task is cancelled on pause, finish and model release. No repeating `Timer` is used.

## 4. Workout timing and pause

`WorkoutTimeSource` supplies monotonic elapsed time and a calendar date. Production uses `ContinuousClock`; `Date` is read to capture the workout's start timestamp. Tests can supply controlled time without waiting for real rest periods. Production creates the ViewModel with `cameraReady: false`; active time begins only after the requested camera start succeeds. Standalone logic tests can declare the camera ready at initialization. Active time includes rest and excludes explicit/system pauses. The calendar timestamp is still captured at model creation, preserving existing summary semantics.

Rest deadlines are expressed on that same active-time scale. Pausing freezes both elapsed time and remaining rest; resuming starts a new active interval without shifting the rest deadline. Refreshes and incoming poses check the deadline against elapsed time, so missed refreshes do not accumulate timer drift.

Pausing clears pose smoothing and calls `SquatCounter.resetMovement()`: the phase returns to `seekingStanding`, intermediate frame counts are cleared, and completed repetitions are retained. Standing must be confirmed again after resume. `reset()` still clears the entire set when a rest period begins; normal movement thresholds are unchanged.

The first finish freezes duration and the existing UUID summary. Retrying storage does not change its fields. `sets` means completed sets plus a current partial set with at least one counted repetition, capped at the target. An empty current set is not added.

Backgrounding, capture interruption and runtime errors now call the same idempotent pause path. Camera readiness alone does not resume the model: returning to foreground, permission changes and interruption end all require an explicit user action. `resetMovement`, rest, completed repetitions and frozen retry summaries keep the stage 3/4 semantics. Native camera behavior still requires iPhone verification.

## 5. Squat detection

Camera: rear-facing, vertical iPhone, 2D sagittal/side angle.

Use visible hip, knee and ankle joint landmarks. Require confidence >= 0.5 on all three landmarks. Compute knee angle with the dot-product formula and clamp the cosine to [-1,1]. Smooth with exponential moving average alpha = 0.35.

Finite-state machine:

```text
SEEKING_STANDING --3 frames angle >=160--> STANDING
STANDING         --3 frames angle <=105--> LOWERED
LOWERED          --3 frames angle >=160--> STANDING + 1 repetition
```

Angles between thresholds do not transition the machine. Missing joints suspend counting and, after 12 missed observations, force re-acquisition of a standing posture. Thresholds and stability rules are prototype-only and need calibration with data.

## 6. Frame orientation and overlay alignment

The detector uses `.right` orientation to interpret the rear camera's sensor stream as portrait. Vision reports normalized points with a lower-left origin; the overlay converts those to the unrotated capture-device coordinate system before calling AVFoundation's `layerPointConverted(fromCaptureDevicePoint:)`. Both camera preview rotation and overlay mapping **must be verified on real device hardware**. Format selection, mirroring and camera position changes require synchronized updates.

## 7. Data schema

Workout: `id: UUID?`, `date: Date`, `duration: Int64`, `repetitions: Int64`, `sets: Int64`. New summaries always have a UUID. The stored attribute is optional to allow migration from the initial schema, then a transaction assigns stable UUIDs to legacy rows.

A single Core Data store contains small session summaries. No video files, pose time series, usernames or cloud data are persisted. The exact legacy model is retained; compatible old SQLite stores migrate through an inferred mapping into a temporary store and are replaced using Core Data APIs. Unknown models and damaged stores produce errors without deleting user data.

The finished workout snapshot is retained separately from `.notSaved`, `.saving`, `.saved` and `.failed` persistence states. All retries reuse the snapshot UUID and fields. The storage checks that identifier before inserting, making retries idempotent within the current single-process app, including after reopening SQLite. See [persistence guarantees and limits](PERSISTENCE.md).

## 8. Known MVP limitations

- No adaptive thresholds or height/calibration flow.
- No push-up recognition or multi-person tracking.
- No background workout mode; foreground camera only.
- An unsaved finished summary exists only in the current process; no draft recovery after force quitting.
- Confidence threshold is heuristic and the first sufficiently visible leg is selected.
- Temporary camera occlusion can invalidate a partially completed squat.
- Camera/overlay transform and sensor thermal performance are unverified.
- Unit tests cover pure counting logic but no automated video-fixture integration tests yet.
