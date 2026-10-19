# Changelog

## Unreleased

## 2.24.3 - 2026-10-19

- Added a searchable multi-application selector in Settings. An empty selection preserves the historical global mode; otherwise application hooks load only in the chosen bundle identifiers.
- Scoped the `mediaserverd` replacement path with a short-lived heartbeat from active `AVCaptureSession` and `ARSession` instances in selected apps, preventing unrelated camera apps from receiving the virtual feed.
- Added an `ARFrame.capturedImage` fallback and changed processed/RAW photo export to prefer the virtual primary image even when private camera metadata cannot be fully round-tripped.
- Added explicit system Camera and WebKit content-process targets for `UIImagePickerController`, `WKWebView`, Safari and WebRTC camera hosts.
- Added a `notifyd` configuration bridge for sandboxed camera clients. Selected bundle state, enable state, source kind and the validated HLS URL no longer depend on direct access to `/var/mobile/Library/Preferences`, which iOS 15 denies inside App Store and TrollStore applications.

## 2.24.2 - 2026-08-15

- Fixed a concrete iOS 15.8.8 shared-frame false-stale failure. Every consumer now maintains freshness in its own monotonic-clock domain and refreshes that observation when the published generation advances or SpringBoard's packed producer-runtime state changes. A zero, future or temporarily stuck direct timestamp can no longer hide an actively published global IOSurface, while a genuinely stopped producer still ages out under the configured policy.
- Unified the direct Darwin-state and control-IOSurface paths behind the same effective timestamp resolver, including bounded producer-heartbeat assistance and a first-observation grace period for newly attached camera processes.
- Kept the SpringBoard volume-hook notify token alive for the process lifetime, with recovery after a real `notify_set_state` failure. Settings no longer remains indefinitely at “scanning SpringBoard volume entries” after the scan has completed.
- Added iOS 15 hardware `volumeIncrease/DecreasePressDown` selector variants to the ABI-validated volume scan, and extended portable protocol and repository regression checks for clock-domain recovery and persistent volume diagnostics.

## 2.24.1 - 2026-08-15

- Removed the global FFmpeg `-flags low_delay` option from the Windows bridge. FFmpeg 8.1.1 rejects that MPEG-2-only forcing flag when the native MJPEG encoder initializes frame threading, which previously produced an immediate `ff_frame_thread_encoder_init failed` / exit `-22` restart loop even though the isolated encoder benchmark passed.
- Upgraded the Windows runtime smoke test to exercise the production software-MJPEG profile (`q=1`, four encoder threads, optimal Huffman tables, passthrough timestamps and FIFO/MPJPEG HTTP output), and added an argument invariant that rejects reintroducing the incompatible low-delay codec flag.

## 2.24.0 - 2026-08-15

- Added a redundant zero-copy video discovery path for iOS 15.8.8. SpringBoard now mirrors the current global IOSurface ID, generation and monotonic timestamp through persistent Darwin notify state, so mediaserverd and application fallbacks can consume the frame even when the tiny control IOSurface cannot be mapped across the sandbox boundary.
- Made control-IOSurface creation optional and rate-limited failed allocation retries to once per five seconds. A control-plane failure no longer turns a valid source into a dropped frame or causes allocation work on every 60 FPS producer callback.
- Added thread-local shared-video failure codes for missing direct/control state, stale publication, frame IOSurface lookup, CoreVideo wrapping and generation races. System and application runtime stages now carry the exact failure reason instead of reporting only “shared source unavailable”.
- Added a dedicated `sharedVideoBus` live status/diagnostic row that reports whether SpringBoard published both discovery channels, direct fallback only, control only, or a concrete producer failure.
- Rebuilt the SpringBoard volume-key integration around an ABI-validated multi-entry dispatch table. It scans known iOS 15 classes plus loaded volume-related classes, covers no-argument actions, hardware `PressDownWithModifiers:` entries and both float/double delta selectors, resolves inherited implementations to their declaring class and preserves original behavior whenever local-media playlist control declines the event.
- Kept bounded startup scans followed by low-frequency rescans for volume classes loaded late, and expanded the status channel to report scan completion plus directional/delta hook counts.
- Extended portable protocol tests and repository validation for the redundant video bus, failure telemetry, control retry backoff, volume-hook status packing, dynamic class scanning and new Settings status row.

## 2.23.0 - 2026-08-15

- Fixed the iOS 15.8.8 mediaserverd compatibility scan so `BWNodeOutput` can be hooked when `emitSampleBuffer:` is inherited instead of declared directly. Direct subclass overrides remain hooked once, without repeatedly wrapping the same inherited implementation.
- Removed the ten-second permanent failure boundary for private camera-class discovery. After bounded fast startup retries, mediaserverd now continues low-frequency scans so a camera graph registered later in the process lifetime can still be attached.
- Added process-liveness heartbeats for SpringBoard and mediaserverd, and now rejects stale producer/pipeline notify values when the corresponding injected runtime is absent or has stopped updating.
- Added persistent, rate-limited video-stage telemetry independent of unified logging. Settings now distinguishes injection, class scanning, Hook installation, unsupported formats, missing shared frames, conversion failure and confirmed system replacement.
- Added application fallback telemetry for real AVFoundation Hook activity, delegate wrapping, preview overlay/frame display and photo replacement. The last stage and monotonic age survive switching from Camera back to Settings and are included in copied diagnostics without being overwritten by an unrelated UIKit process merely starting.
- Bounded all hot-path diagnostic writes to at most four transitions per second and one repeated state per second, preserving fail-open media behavior without turning diagnostics into per-frame notify traffic.
- Extended source validation and portable protocol regression tests to enforce the new liveness/event layout, inherited-method coverage, persistent retry behavior and both system/application diagnostic paths.

## 2.22.0 - 2026-08-15

- Fixed another concrete local-import false-negative path: file providers and Photos may return a temporary URL or suggested name without a usable media suffix. Settings now derives the preferred extension from the URL content type, repairs unknown temporary suffixes and links only the public iOS 15 Uniform Type Identifiers framework.
- Added a shared fresh-asset retry loader. Import and playback now retry an immediate parse failure or empty-track result once with a new `AVURLAsset`, while retaining one 30-second overall deadline and at most 100 ms cancellation polling instead of multiplying the timeout.
- Added one bounded local-reader recovery after a transient `AVAssetReader` failure. The stale asset/track geometry cache is discarded before reopening, but a corrupt or unsupported file still fails open after the single retry rather than entering an infinite restart loop.
- Extended repository validation to require content-type filename repair, fresh-asset retry budgeting, source-switch cancellation and bounded decoder recovery, and re-ran the complete Windows transport/runtime self-test.
- Fixed a CI false-green condition found during log review: Windows source checks now stop after every nonzero child exit code, and the standalone directory has deterministic CRLF checkout bytes on Windows and Linux so its committed size/SHA-256 manifest validates identically on both runners.
- Kept the active `AVURLAsset` cancellation handle alive through video-geometry loading and made retry cleanup identity-aware, so stopping or replacing a source cancels the complete metadata transaction without allowing an older attempt to clear a newer handle.
- Upgraded every pinned GitHub-maintained workflow action to its current Node.js 24 release SHA (`checkout` v7.0.1, `cache` v6.1.0 and `upload-artifact` v7.0.1), eliminating the platform's Node.js 20 forced-migration warning while preserving immutable action references.

## 2.21.0 - 2026-08-15

- Unified Settings import and SpringBoard playback behind one bounded asynchronous video/audio track loader. Stopping or switching a local source now cancels pending AVFoundation metadata work within the reader lifecycle instead of leaving a stale load to finish later.
- Asynchronously preloaded and cached each local video track's `preferredTransform` and `naturalSize` before playback. Looping no longer repeats container/geometry inspection, and slow metadata can no longer block the serial reader indefinitely before rotation is applied.
- Made Photos imports require an actual video track while Files continues to accept either video or audio. An audio-only or incomplete Photos representation can no longer appear to import successfully and then fail as a video source.
- Removed synchronous HLS `AVPlayerItem` track enumeration and nominal-FPS reads from the ready-to-play callback. Polling adaptation now loads video-track metadata asynchronously, ignores callbacks from a replaced player item and cancels outstanding asset loading on stop.
- Extended repository invariants and the iOS 15.8.8 device plan to cover deferred track geometry, source-switch cancellation, loop reuse, Photos video validation and non-blocking HLS metadata adaptation.

## 2.20.0 - 2026-08-14

- Replaced immediate synchronous local-file track inspection with bounded asynchronous `AVAsset` video/audio track loading, preventing Photos, iCloud and recently edited assets from being rejected before their track metadata is ready.
- Split local import failures into track-loading timeout, AVFoundation parsing failure and confirmed empty-container results; the Settings alert now preserves the underlying parser description instead of reporting every case as “no recognizable tracks.”
- Changed PHPicker from the untranscoded Current representation to the most compatible representation, improving iOS 15 import reliability for rotated, edited, HDR and cloud-backed Photos videos.
- Added repository invariants that reject reintroducing synchronous track inspection or the less-compatible Current Photos representation.

## 2.19.0 - 2026-08-14

- Removed the entire retired Auto Layout dashboard implementation from the PreferenceLoader binary, including its table-header mutation and layout state, so iOS 15 Settings now compiles only the native specifier list and optional read-only row refresh.
- Added type-gated runtime preference readers in both the Settings bundle and injected media processes. Arrays, dictionaries, oversized numeric strings, NaN/infinity, fractional integers and extreme values now resolve to safe defaults without receiving incompatible Objective-C selectors or reaching `llround` before range validation.
- Bounded network URL, local path and restart-token lengths before parsing or display, and normalized pasted stream URLs before they are persisted.
- Made shared-media Darwin notify registration recover from transient `notifyd` failures. Successful tokens remain lock-free on the per-frame hot path while failed registrations retry at a five-second ceiling instead of disabling discovery for the process lifetime.
- Added portable preference-boundary regression tests under ASan/UBSan and repository invariants that reject reintroduced custom Settings dashboard code, unchecked scalar reads, unbounded preference strings and one-shot shared-bus token registration.

## 2.18.0 - 2026-08-14

- Changed the iOS 15 Settings entry to launch with native PreferenceLoader rows only; the custom Auto Layout table header is no longer installed during controller loading, and the preference bundle no longer links QuartzCore solely for dashboard decoration.
- Deferred optional runtime-row refresh from `viewWillAppear:` until `viewDidAppear:` so Preferences.framework finishes its navigation/table transition before individual specifiers are reloaded.
- Replaced animated private-row reload calls with the older one-argument selector available across iOS 15 Preferences.framework variants.
- Added an Objective-C exception boundary around optional status refresh, timer callbacks, source-specific reloads and legacy header cleanup. On an implementation mismatch the timer is stopped and the native settings list remains usable instead of terminating the Settings process.
- Normalized every stored string, boolean, integer and real preference before Root.plist loads; malformed legacy plist values, NaN, invalid enums and out-of-range sliders are repaired to safe typed values instead of reaching a PreferenceLoader cell or receiving an incompatible selector.
- Added repository invariants that reject launch-time custom header installation, QuartzCore coupling, pre-appearance status refresh and the less-compatible animated selector.

## 2.17.0 - 2026-08-14

- Generation-gated every screen, local-file and network error callback so a delayed failure from an already stopped producer can no longer overwrite the live status of a newly selected source.
- Added an explicit non-looping local-media completion lifecycle. Natural EOF now reports “completed”, immediately invalidates the shared PCM ring so the physical microphone resumes without the former freshness tail, and leaves video retention to the configured last-frame policy.
- Corrected source-error status selection to honor “hold last frame”; an existing frame is no longer reported as held when the user explicitly disabled retention.
- Reused four process-lifetime Darwin notify tokens in the visible Settings dashboard and coalesced repeated CFPreferences synchronizations across its one-second refresh pass, removing repeated register/cancel and disk/domain synchronization churn.
- Bounded missing-screen-geometry retries to the same roughly 4 Hz cadence as rotation polling, preventing transient UIKit unavailability from scheduling one SpringBoard-main query per capture frame.
- Extended repository invariants and the iOS 15.8.8 device plan for stale callback isolation, local EOF audio release, Settings polling overhead and screen-geometry retry storms.

## 2.16.0 - 2026-08-14

- Rebuilt the iOS PreferenceLoader page around a dynamic, accessibility-aware status card that shows enablement, selected source, SpringBoard producer health and recent mediaserverd video activity without requiring the user to interpret raw controls.
- Added a one-second visible-page refresh loop limited to explicitly read-only status rows; it stops when the controller disappears, never reloads URL editors/sliders during input, and provides a manual navigation-bar refresh action.
- Reordered the control panel into source selection, source-specific controls, runtime recovery, stability and version sections. Every source now has an in-context operation guide, configuration summary and missing/invalid source warning.
- Added a read-only local media library viewer with naturally sorted filenames, current-item marker, file count and aggregate storage, while preserving the existing non-destructive import/clear behavior.
- Added clipboard diagnostics covering device/iOS, source, pipeline, local transform, volume hook and stability state. Network output is deliberately limited to protocol plus host, so URL query parameters and access tokens are not copied.
- Extended repository validation to lock down dashboard lifecycle, live-row scope, required actions/frameworks and diagnostic redaction before a UI release can pass CI.

## 2.15.0 - 2026-08-14

- Replaced the process-global local-audio read position with an independent cursor per `BWNodeOutput` and application output, then added a 30 ms bounded startup reservoir so concurrent CaptureSessions neither steal PCM nor underflow at AVAssetReader batch boundaries.
- Added a stateful streaming resampler that preserves fractional phase and look-ahead frames across microphone callbacks; 44.1/48/96 kHz outputs no longer over-consume interpolation samples or restart phase on every sample buffer.
- Removed the synchronous SpringBoard-main `UIScreen` geometry query from every screen frame. Geometry is now asynchronously coalesced at roughly 4 Hz, including retry-safe handling when UIKit temporarily cannot expose a screen.
- Made HLS frame polling adapt to twice the sender's nominal frame rate within 30–240 Hz, and changed transient MJPEG VideoToolbox failures from a process-lifetime CPU fallback to a 30-second retry cooldown.
- Added Settings runtime rows for SpringBoard source production and recent mediaserverd video replacement plus an atomic “reload current source” action that preserves the selected URL/file and all presentation settings.
- Extended protocol tests and repository invariants for independent audio cursors, buffered startup, continuous resampling, screen hot-path isolation, adaptive network decoding and the new recovery UI. Private `BWNodeOutput` behavior still requires the documented iOS 15.8.8 device run.

## 2.14.0 - 2026-08-14

- Moved per-frame video generation/Surface ID/freshness into a persistent shared IOSurface control block and audio freshness into the PCM ring header. Darwin notify is now a lifecycle discovery channel only, eliminating per-frame cross-process state traffic while retaining retryable remapping after producer changes.
- Preserved multiple converted source generations, added a non-blocking latest-complete-frame path when the VideoToolbox lane is occupied, and bounded the LRU converted-frame cache to 64 MiB so multi-node continuity cannot cause unbounded 4K memory growth.
- Added a 128-slot lock-free runtime-class dispatch cache for `BWNodeOutput` original IMP lookup, with positive entries refreshed when later dyld scans hook a more specific subclass.
- Hardened shared-control and audio-ring discovery against transient IOSurface lookup failures, Surface ID reuse and invalid protocol layouts, and added protocol alignment/freshness plus repository invariants for the new hot path.
- Expanded the A10/iOS 15.8.8 device plan with notification-rate, producer-restart, cache-budget and contended multi-output evidence; private camera-graph behavior still requires the documented real-device acceptance run.

## 2.13.0 - 2026-08-14

- Replaced the process-global system-heartbeat fallback gate with propagating per-sample and per-pixel-buffer evidence, then scoped compatibility-preview state to each `AVCaptureVideoDataOutput` inside its own `AVCaptureSession`; success in one camera graph can no longer suppress another graph's fallback.
- Made the IOSurface cache-race ownership transition explicit: the cache winner receives its own use-count lease before the losing wrapper's lease is retired, with repository invariants covering the balanced handoff.
- Reused six Darwin notify tokens for each process lifetime, removed media-bus `notify_post` calls, limited freshness state writes to 10 Hz, made the audio Surface state one-shot per ring, and limited diagnostic pipeline heartbeats to 4 Hz.
- Split frame cache/pool locking from the serialized VideoToolbox session lane, added a post-wait cache recheck so sibling nodes do not duplicate the same conversion, and rate-limited telemetry that separates session wait time from actual pixel-transfer time.
- Expanded the iPhone 7 Plus/iOS 15.8.8 device plan with concurrent-session isolation, one-hour IOSurface/footprint stability, and frame-budget evidence; CI compilation remains explicitly distinct from private `BWNodeOutput` device validation.

## 2.12.0 - 2026-08-14

- Applied each local asset track's `preferredTransform` before the user's 0°/90°/180°/270° control, then combined both rotations and mirrors into one GPU render instead of silently treating encoded portrait pixels as upright.
- Made horizontal mirroring operate in final displayed coordinates, validated swapped output dimensions for quarter-turn rotations, and published a SpringBoard first-frame transform status back to Settings.
- Added a sanitizer-tested pure-C preferred-transform resolver covering all right-angle rotations, mirrored variants, scale/noise tolerance, degenerate matrices and rejection of arbitrary affine angles.
- Added multi-selection for Files (up to 64 items per import) and Photos (up to 20 videos), ordered batch results, serialized stable-name reservation and partial-failure reporting so a usable volume-button playlist can be created in one operation.
- Rebuilt the volume switch path around a freshly enumerated playlist, verified preference persistence, forced an immediate SpringBoard reader reload, retained the original system-volume behavior when fewer than two videos exist, and added a signature-checked `_changeVolumeByDelta:` fallback beside the direct button hooks.
- Added Settings diagnostics for imported playlist size, installed volume-hook path, and the transform actually published by SpringBoard; project validation now requires these runtime checks and the orientation test workflow.

## 2.11.0 - 2026-08-14

- Fixed every `PSLinkListCell` by explicitly routing it through `PSListItemsController`, so “替换来源”、本地解码质量和本地旋转 no longer open an empty settings page.
- Replaced editable local-media paths with a native action sheet that can select video/audio from Files or video from Photos, then automatically stores the selected stable path.
- Added coordinated security-scoped import into `/var/mobile/Media/VirtualCamPro/`, collision-free filenames, free-space reserve checks, staging copies, audio/video track validation and atomic finalization; existing files are never overwritten.
- Added current-media status and a non-destructive clear action. Imported files remain available for volume-button playlist navigation instead of being deleted behind the user's back.
- Extended source and package validation to reject empty link-list controllers, missing picker actions/frameworks, missing `Root.plist`, or missing PreferenceLoader registration before a release can pass CI.

## 2.10.0 - 2026-08-14

- Made network sources sender-authoritative: phone rotation, mirroring, FPS, JPEG quality, aspect and decode-size preferences are ignored for HLS/MJPEG, and network/ screen sources always preserve the native microphone.
- Split MJPEG socket parsing from ImageIO decode with a one-frame latest-only decode slot; full sender dimensions are decoded without EXIF orientation or phone-side thumbnailing.
- Added SOF dimension extraction and a real-time VideoToolbox JPEG decode path that requests an IOSurface-backed NV12 buffer, reports whether hardware acceleration was actually selected, and safely falls back to ImageIO after unsupported or repeated decode failures.
- Added five-second MJPEG health telemetry for parsed, decoded, superseded and failed frames plus average decode time, making phone decode pressure distinguishable from sender/network loss.
- Added local-only decode-size/FPS controls, late-video-frame rejection, allocation-free contiguous PCM reads, and volume-up/down navigation through naturally sorted videos in the selected local directory.
- Replaced second-scale Windows buffering with bounded adaptive queues (64 MiB/4-frame/3-frame floors, roughly 250/250/150 ms burst targets and a 1 MiB TCP send buffer) and changed HLS defaults to 250 ms segments, an Apple-compatible six-segment live window and `ultrafast` encoding.
- Added current-mode MJPEG capacity preflight, adaptive Huffman-table selection, and runtime-tested Intel Quick Sync MJPEG offload; advertised but unusable hardware sessions fall back to software without changing OBS resolution, FPS or quality.
- Added independent-segment and program-date-time HLS metadata, atomic temporary segment publication, and HTTP runtime coverage for HEAD, CORS, byte ranges, unsatisfiable ranges, unsafe paths and unsupported methods.
- Replaced the manual system/compatibility split with one SpringBoard producer, a three-slot global IOSurface video bus, and automatic system-heartbeat-based AVFoundation failover.
- Added explicit cross-process IOSurface use-count leases; synchronous converters release after transfer, Core Animation retains through display commit, and photo snapshots deep-copy before asynchronous use so producer pools cannot recycle visible storage.
- Moved all HLS/MJPEG decoding out of `mediaserverd` and application processes; consumers now map the same IOSurface instead of opening duplicate connections or decoding duplicate frames.
- Added direct SpringBoard screen rendering into IOSurface and paced local MP4/MOV/MP3 reading on a shared asset timeline.
- Added a three-second atomic IOSurface PCM ring and format-preserving system/application audio replacement; pure audio files replace the microphone while preserving physical camera video. Interleaved and non-interleaved LPCM now use a correctly shaped `AudioBufferList`, retain sample attachments and consume the ring with a continuous, overrun-resynchronizing cursor.
- Extended the `BWNodeOutput` path to classify both color and PCM samples while strictly passing depth, disparity, metadata, compressed and unknown formats through unchanged.
- Narrowed application injection to AVFoundation video/audio output, preview and photo classes; all failed private lookups and media conversions remain fail-open.
- Consolidated the ready-to-run Windows control center, official Rootless package, integrity manifest, and current deployment guide under `VirtualCamPro-Windows-Control-Center/`; removed duplicate root launchers and obsolete local build debris.
- Made the package-free Windows GUI path safe on clean machines, preserved PowerShell test failures through the CMD launcher, and switched the CI staging directory to an artifact-uploader-safe ASCII name.
- Decoupled DirectShow capture from slow HTTP clients with bounded queues and four-thread MJPEG encoding without reducing configured FPS or JPEG quality.
- Made compatibility-mode preview display the exact converted application output frame, and made photo preview, pixel-buffer, CGImage, and file representations share one atomic source-frame snapshot.
- Kept 60 FPS as the local-file default while removing phone-side network rate control.
- Bypassed the Lanczos scale/crop stage when OBS already publishes the exact canvas, preserving source pixels while reducing filter CPU load at 1080p60 and above.
- Reworked the 60 FPS MJPEG receive hot path around a forward cursor and 1 MiB batched compaction instead of shifting the buffer after every frame, while retaining the 24/32 MiB frame and receive safety limits.
- Serialized MJPEG parser/pool teardown across reconnects and memory-pressure callbacks, revalidated the active session before frame delivery, and raised the bounded decode-pool allowance to six buffers to prevent transient fail-open flashes during photo/preview fan-out.
- Added read-back verification for replacement dimensions and authentic TIFF/EXIF/GPS/Apple metadata, including exact Apple maker-dictionary equality, and removed the metadata-free UIKit JPEG fallback; an unverifiable replacement now preserves the original camera file.
- Stopped attaching or exposing depth, disparity, portrait/semantic mattes, HDR gain maps, or secondary images from the physical scene to a different network image; authentic device metadata is preserved without internally contradictory scene payloads.
- Made the Settings stream test use the production incremental JPEG parser instead of raw SOI/EOI byte searches, and append receive chunks without temporary `NSData` copies.
- Pinned all GitHub Actions dependencies to the verified current release commit SHAs and made project validation reject floating CI action references.
- Pinned the Theos and iPhoneOS 16.5 SDK source commits used by packaging, eliminating two remaining floating build inputs.
- Aligned the installed `virtualcampro-config` URL checks with runtime rules (scheme, host, credentials, fragments, whitespace, and length) and added a non-mutating configuration self-test to both CI workflows.
- Serialized and cached the complete `AVCapturePhoto` file representation, including authentic-original fallback results, so repeated or concurrent client reads cannot re-encode different data.
- Gated every photo rewrite on a proven replacement frame: compatibility mode requires an atomic network snapshot, while system mode requires a receiving/holding status from `mediaserverd`; disabled, startup, and fail-open photos now remain byte-for-byte on the original API path.
- Added an explicit cross-process “holding last replacement frame” status so photo consistency and Settings diagnostics remain accurate while the network reconnects.
- Invalidated cross-process “receiving” state whenever critical memory pressure or a source transform clears the latest frame, preventing a concurrent photo from being misclassified as replaced.
- Moved high-rate HLS pixel-buffer polling from the UI main queue to a user-interactive serial queue while keeping AVPlayer setup/teardown on the main thread.
- Added a PowerShell 5.1 WinForms control center for visual phone preflight, package selection, custom phone FPS, one-click installation/configuration, live status logs, and installed runtime verification.
- Integrated `start-obs-vcam.bat` into the control center with direct bridge start, bridge diagnostics, and optional automatic start after successful phone deployment.
- Added an optional non-secret installer event log and a read-only Verify mode while keeping all SSH and sudo passwords inside the native OpenSSH terminal.
- Fixed remote verification under the default iOS zsh by avoiding its read-only `status` parameter.
- Added end-to-end uploaded-package SHA-256 verification, failure-path upload cleanup, SSH keepalives, and URL query-token redaction from Windows logs.
- Made OBS preflight fail with exit code 5 when the requested DirectShow mode is unavailable, while preserving a safe permissive-mode capture fallback for genuinely different rates.
- Added a reproducible Windows standalone builder, immutable-file manifest verification, complete CLI launchers, and an aggregate offline self-test.
- Bounded orientation pixel-buffer allocation, tightened phone URL validation, normalized the settings FPS slider to integers, and required a complete JPEG during the in-phone stream test.
- Expanded incremental JPEG parser regression coverage for concatenated frames, split markers, missing SOI, and invalid segment lengths.
- Hardened the standalone control center's mutable CMD configuration with a strict variable whitelist, command-metacharacter rejection, verify-before-load launchers, and rejection of every unmanifested payload.
- Made package-free standalone builds explicit in their signed manifest contract, so an upgraded Windows control center can be distributed without silently bundling a stale iOS package.
- Rejected links, reparse points, and all unmanifested files during standalone verification, closing path-redirection and side-load gaps around the hashed payload.
- Froze the replacement route once per `AVCapturePhoto` (original, compatibility, or system pipeline), preventing network-state changes from making pixels, file data, depth, and mattes disagree for the same capture.
- Deferred compatibility-preview BGRA conversion until a preview layer actually renders, eliminating an unnecessary per-frame GPU pass in headless recording and processing clients.
- Removed the legacy 60 FPS ceiling from Windows OBS/profile parsing and sender output; network receivers follow source cadence while local-file FPS remains independently configurable.
- Made DirectShow `rtbufsize` resolution/FPS-aware with a 64 MiB floor and roughly 250 ms burst target capped at 256 MiB.
- Removed the FFmpeg `fps` filter from exact OBS/DirectShow modes, preserving capture timestamps without jitter-driven duplication or drops; rate conversion remains only for file sources and explicitly permissive mismatched fallbacks.
- Raised replacement-photo JPEG fallback quality to the quality-scale maximum (`1.0`) while retaining read-back metadata verification and authentic-original failover.
- Raised the Windows MJPEG default from quality 5 to encoder-maximum quality 1 after a local 1080p60 stress run completed at roughly 17× real time; users may still choose a larger qscale explicitly, but no automatic quality reduction exists.

## 2.8.0

- Added a latest-frame-wins phone processing queue that coalesces pending frames before GPU orientation/conversion, preventing load spikes from turning into steadily increasing latency.
- Changed bursty MJPEG handling to discard completed backlog frames and decode the newest complete JPEG available in each network callback.
- Added an in-phone stream test that reads live `mediaserverd` receive/reconnect state without stealing the single MJPEG connection, and verifies HTTP/content/JPEG/HLS data directly when the system pipeline is inactive.
- Added authenticated OBS WebSocket 5 control for safely starting or refreshing only Virtual Camera when OBS is already running, without terminating OBS or losing unsaved scenes; the launcher degrades to a precise one-time action when the server is disabled.
- Added `install-phone.bat --setup`, which installs the package, derives the correct computer-side LAN address, writes the stream URL/FPS to the phone, and notifies the running plugin.
- Hardened phone installation with upload-size validation, exact installed-version verification, successful-upload cleanup, and an atomically written packaged `virtualcampro-config` utility.
- Reused the Core Image orientation color space and expanded static/Windows self-tests to cover the new recovery, installation, and low-latency paths.

## 2.7.0

- Read the current saved OBS profile automatically on every launcher start and OBS reconnect, including base canvas, scaled output, and common/integer/fractional FPS formats.
- Made OBS resolution and FPS automatic by default while retaining explicit command-line and environment overrides.
- Cross-checked saved OBS settings against the DirectShow mode actually published by Virtual Camera so stale live state cannot silently override a newly saved profile.
- Added safe OBS INI parsing, current-profile resolution, path validation, and offline regression coverage.

## 2.6.0

- Accepted custom Windows rates from 1 through 60 FPS as integers, decimals, or rational expressions such as `30000/1001`, with locale-independent FFmpeg arguments.
- Tightened OBS mode matching to distinguish fractional NTSC rates such as 29.97/59.94 from 30/60 while tolerating harmless driver reporting noise.
- Added one-command FPS overrides to the OBS launcher and validated optional phone FPS configuration in `setup-config.sh`.
- Expanded the local-file FPS control to 1–240 while removing it from network decode policy.

## 2.5.0

- Required an exact OBS DirectShow resolution/FPS match before streaming, explicitly selected the advertised input mode, and reduced the real-time/thread queues so stale frames are dropped instead of accumulating hundreds of megabytes of latency.
- Added `fill`, `fit`, and `stretch` output geometry modes, defaulted to 1080p30 quality 5, and diagnosed visible OBS image sources that still use non-adaptive free transforms.
- Recognized Windows interrupt exit codes so a normal `Ctrl+C` / FFmpeg `Immediate exit requested` shutdown does not enter the disconnect-recovery loop.
- Preserved original EXIF/GPS/TIFF properties in an ImageIO JPEG fallback when the source photo container cannot be safely rewritten, with explicit rate-limited diagnostics before the final metadata-free UIKit fallback.
- Included the WebKit content process in the application compatibility filter while retaining the existing non-spoofing device model: browsers still enumerate the built-in iPhone cameras whose frames are replaced.

- Added independent preference, stream, and transform generations so stale asynchronous frames cannot overwrite a newly selected URL or orientation.
- Replaced repeated whole-buffer MJPEG end-marker scans with an incremental JPEG marker/segment parser that correctly skips embedded JPEG data in metadata segments.
- Bounded MJPEG frames at 24 MiB and the receive buffer at 32 MiB, rejected obvious non-image responses early, and rate-limited malformed-stream diagnostics.
- Reused the MJPEG RGB color space, reduced inactive preview polling to 1 FPS, and cached rewritten photo data for repeated access.
- Reused semantically equal camera format descriptions and raised the bounded per-format in-flight buffer allowance from four to six to reduce fail-open flashes under pipeline fan-out.
- Rebuilt the Windows launchers around a PowerShell 5.1 core with strict typed configuration, port-owner and LAN URL diagnostics, OBS DirectShow frame probing, ffprobe input validation, yuvj420p output, disconnect recovery, bounded failure retries, and Windows CI self-tests.
- Added a password-safe Windows rootless phone preflight and installer that validates SSH, real `sudo` elevation, `dpkg`, package naming and SHA-256 before SCP installation and final package-state verification.
- Corrected rootless installation, emergency-disable, and removal documentation to use `mobile + sudo`, with explicit recovery guidance for inactive jailbreak or `nosuid` failures.

## 2.4.0

- Added one-pass GPU orientation and horizontal mirroring for local-file sources before fan-out to camera outputs; network and screen sources bypass it.
- Added validated MJPEG decode limits for 1280, 1920, 2560, and experimental 3840-pixel sources, defaulting to 1920 for the A10 device profile.
- Reused the normalized source frame across preview, photo, video, browser, and third-party camera paths instead of rotating every downstream output.
- Cleared stale oriented frames immediately when orientation preferences change and retained fail-open behavior when GPU rendering is unavailable.
- Upgraded the Windows MJPEG launcher to 1080p by default with 720p/1080p/1440p/2160p presets, Lanczos scaling, configurable MJPEG quality, and lower-latency packet flushing.
- Expanded OBS instructions for scene rotation, media pause/resume, hotkeys, and quality/performance tuning.

## 2.3.0

- Removed the application-layer startup race by installing a pass-through video delegate proxy independently of current stream readiness.
- Made preview fallback layers react to preference changes without requiring them to exist only after the stream becomes active.
- Regenerated cached photo buffers when the full-resolution or preview template changes dimensions or pixel format.
- Preserved the original photo container, metadata, secondary images, depth/disparity, portrait matte, semantic mattes, and HDR gain-map payloads when ImageIO can rewrite the format.
- Kept original audio, depth, disparity, metadata, and unsupported image formats on the fail-open path.
- Expanded the iPhone 7 Plus validation matrix across photo, Live Photo, portrait, panorama, burst, video, slow motion, time lapse, third-party capture, and browser capture.

## 2.2.0

- Added runtime-validated `mediaTypeIsVideo` filtering and a supported color-format allowlist before frame replacement.
- Replaced per-frame string/dictionary cache keys with bounded C-structure caches and LRU pixel-buffer pools.
- Added format-description identity to converted-frame cache keys so outputs with different color/aperture extensions cannot share incompatible attachments.
- Reused the original camera format description only after `CMVideoFormatDescriptionMatchesImageBuffer` succeeds, with safe regeneration and per-output caching otherwise.
- Added pixel-buffer allocation thresholds and dispatch memory-pressure handling that tears down recyclable buffers and VideoToolbox state.
- Replaced the coordinator's per-frame `@synchronized` monitor with short `os_unfair_lock` critical sections and releases outside the lock.
- Added stricter sample width, height, subtype, and format-description consistency checks with fail-open behavior.

## 2.1.0

- Added a first-frame/stalled-frame watchdog for HLS and MJPEG connections.
- Added configurable last-frame retention and stale-frame timeout behavior.
- Cached converted camera buffers for repeated `BWNodeOutput` formats.
- Added MJPEG decode throttling, 1920-pixel bounded thumbnail decoding, and reusable pixel-buffer pools.
- Reduced compatibility-mode overhead when the system pipeline is selected.
- Added runtime method-signature validation before installing the private camera hook.
- Added portrait/landscape modes to the Windows MJPEG launcher.
- Added package install/removal scripts that reload affected system processes.
- Restricted the package to the validated iOS 15 release family.

## 2.0.0

- Replaced the overlay-only design with a default `mediaserverd` frame-replacement path.
- Added an application-layer compatibility path for video data, preview, and photos.
- Rebuilt HLS/MJPEG reception, preferences, rootless packaging, documentation, and CI validation.
- Removed device capability spoofing, authorization bypass, jailbreak hiding, and anti-debugging code.
