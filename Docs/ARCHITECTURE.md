# Architecture Decision Record — RepsCounter v0.1

**Status:** In Development. Updated 27 October 2026. Camera lifecycle, file-header changes and front/rear switching are merged through PR #6 (`main` at `5d3eb1d`). Squat diagnostics and continuity fixes are in `feature/squat-diagnostics` awaiting review.

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
- A separate serial frame delegate owns Vision processing. An `OSAllocatedUnfairLock` confines mutable detector state and serializes invalidation. No raw buffers or Vision objects are sent to MainActor; the lock confines processor state, including cross-queue invalidation.
- Analysis retains the 80 ms interval and AVFoundation late-frame discard. A newest-only pose stream, run generation, camera position, actual rotation, monotonic analysis timestamp and 250 ms age limit reject obsolete results at MainActor.
- `CameraService`, the coordinator, ViewModel and UIKit updates are MainActor-isolated. Permission requests and pending starts/switches are coalesced/cancellable; finish is terminal. Session notifications travel separately from frames and are removed on shutdown.
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

Camera: front or rear, vertical iPhone, 2D sagittal/side angle. Front capture is the default; body-angle thresholds are unchanged.

Use visible hip, knee and ankle joint landmarks. Require finite confidence in [0.5,1] on all three landmarks. Initially select the valid leg with the higher minimum joint confidence; retain it while valid instead of alternating with confidence fluctuations. A fallback leg starts a new filter and requires fresh standing. Compute the aspect-corrected knee angle with the dot-product formula, reject nonfinite/degenerate geometry and clamp the cosine to [-1,1]. Smooth the selected leg with exponential moving average alpha = 0.35.

Finite-state machine:

```text
SEEKING_STANDING --3 frames angle >=160--> STANDING
STANDING         --3 frames angle <=105--> LOWERED
LOWERED          --3 frames angle >=160--> STANDING + 1 repetition
```

Angles between thresholds break the current confirmation sequence. A missing/invalid measurement immediately clears unfinished movement while preserving completed repetitions. A change of analyzed leg also resets EMA and movement; observations from different legs cannot complete one repetition. Thresholds, confidence cutoff, EMA coefficient and three-frame confirmation are unchanged and remain prototype assumptions.

The ViewModel uses the existing injected monotonic clock to check continuity before processing a pose and during time refresh. A gap over 250 ms between valid delivered poses clears tracking and requires standing again. This is a conservative continuity policy, not a biomechanical threshold. Its duration matches the camera's existing age budget, but frame age and delivery interval are distinct checks. Low effective frame rates can increase missed repetitions and require hardware evaluation. Workout duration/rest and immutable save summaries are unchanged.

### Debug diagnostics

`SquatDiagnostics` is a MainActor-published value assembled from analyzer/counter state. `SquatDiagnosticsView` renders both raw leg angles, six confidence values, selected leg, EMA, phase, thresholds, consecutive observations and a decision/reset reason. The controller subscribes weakly and renders only while the panel is enabled. Debug-only layout reserves a scrollable right column and separate space for workout metrics/controls; disabling it restores the normal layout. The panel, controls, snapshot and callback compile only under `#if DEBUG`; the project sets the condition only for Debug.

No camera images, video, pose time series or diagnostic files are stored. Missing data is displayed explicitly rather than treated as depth. Unit tests use synthetic points and controlled time; they do not measure real Vision accuracy. Front-facing body depth is not generally observable from the current 2D angle, even with a correct overlay. A separately proposed `VNDetectHumanBodyPose3DRequest` experiment is documented but not implemented in [SQUAT_DIAGNOSTICS.md](SQUAT_DIAGNOSTICS.md).

## 6. Camera switching, orientation and overlay alignment

`CameraService` defaults to front capture and commits `CameraConfiguration` only after the backend reports a running session. A switch increments the run generation, publishes `.switching`, pauses the workout and replaces the input within the same capture actor. The previous delegate is invalidated, capture stops, and the frame queue drains before a new delegate is attached. Failed configuration attempts restore the previous input when AVFoundation permits and remain paused for explicit retry. There is never a second capture session.

The coordinator preserves whether the workout was active before switching. Only a successful switch may restore that active state; switching on pause keeps the workout paused. Duplicate requests are ignored. Background, interruption, runtime error and finish invalidate pending auto-resume. Existing `resetMovement`, timing and UUID save semantics remain unchanged.

The portrait output rotation comes from the selected device: iOS 27 uses `RotationCoordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)`. On iOS 17–26, the isolated typed compatibility helper sets the legacy portrait orientation and reads the actual `videoRotationAngle`; it retains one explicit deprecation diagnostic. A fixed 90° angle is insufficient for different sensor mountings. The input is physically rotated and unmirrored, so Vision uses `.up`, with aspect ratio from actual pixel-buffer dimensions.

`CameraFrame` and `BodyPose` carry the effective quarter-turn angle. `PoseGeometry` converts lower-left Vision coordinates back to unrotated top-left capture coordinates for 0/90/180/270 degrees. `AVCaptureVideoPreviewLayer.layerPointConverted` then handles preview orientation, video gravity and the single front-camera mirror. No second horizontal flip or production crop implementation is added. Mathematical conversion tests use synthetic buffers and a test-only projection model; they do not validate actual sensor/preview behavior. See [compatibility rationale and iPhone 15 Pro checks](CAMERA_LIFECYCLE.md).

## 7. Data schema

Workout: `id: UUID?`, `date: Date`, `duration: Int64`, `repetitions: Int64`, `sets: Int64`. New summaries always have a UUID. The stored attribute is optional to allow migration from the initial schema, then a transaction assigns stable UUIDs to legacy rows.

A single Core Data store contains small session summaries. No video files, pose time series, usernames or cloud data are persisted. The exact legacy model is retained; compatible old SQLite stores migrate through an inferred mapping into a temporary store and are replaced using Core Data APIs. Unknown models and damaged stores produce errors without deleting user data.

The finished workout snapshot is retained separately from `.notSaved`, `.saving`, `.saved` and `.failed` persistence states. All retries reuse the snapshot UUID and fields. The storage checks that identifier before inserting, making retries idempotent within the current single-process app, including after reopening SQLite. See [persistence guarantees and limits](PERSISTENCE.md).

## 8. Known MVP limitations

- No adaptive thresholds or height/calibration flow.
- No push-up recognition or multi-person tracking.
- No background workout mode; foreground camera only.
- An unsaved finished summary exists only in the current process; no draft recovery after force quitting.
- Confidence is not an anatomical-angle accuracy estimate; the selected valid leg is retained, but 2D projection can still hide squat depth.
- Any unreliable measurement, leg change or observation gap over 250 ms intentionally invalidates a partially completed squat; low frame rates may reduce recall.
- Camera/overlay transform and sensor thermal performance are unverified.
- Unit tests cover pure counting logic but no automated video-fixture integration tests yet.
