# Progress Log: AI Personal Sticker V1

## Session: 2026-08-02

### Phase 1: Safe project scaffolding

- **Status:** complete
- The product owner explicitly approved starting implementation.
- Created isolated implementation worktree `/tmp/personal-sticker-v1.vzB7Ua` on branch `codex/personal-sticker-v1`, based on the approved planning branch.
- Confirmed the original `main` worktree remains untouched.
- Verified against current Apple documentation that user-generated stickers require a coded iMessage extension using `MSStickerBrowserViewController`; enabling the media presentation context exposes it in the system Stickers surface rather than only inside Messages.
- Replaced the legacy diary source target with a modular SwiftUI shell for the temporary product name “贴贴”.
- Added photo selection, the fixed twelve-reaction flow, deterministic offline generation, local caption editing, pack review, persistence, favorites, deletion, sharing, and empty/error/loading states.
- Added a coded Messages extension that reads approved local PNG files through an App Group and presents them with `MSStickerBrowserViewController`.
- Regenerated the Xcode project from `project.yml` with distinct new-product bundle identifiers for the containing app and extension.
- No simulator was booted, so runtime UI inspection remains pending; proceeding with non-launch build validation first.
- Fixed caption editing so the output PNG is re-rendered locally from caption-free base artwork; the image model never needs to draw Chinese text.
- Reduced mock sticker output to the standard 408 × 408 medium sticker size.
- Completed a clean generic iOS Simulator build of both the app and embedded Messages extension.

### Phase 0: Product and implementation planning

- **Status:** in_progress
- **Started:** 2026-08-01
- Actions taken:
  - Audited the existing SwiftUI app, persistence, widgets, subscription work, and App Store positioning.
  - Interviewed the product owner one decision at a time.
  - Defined the personal-sticker domain language and four architectural decisions.
  - Confirmed iOS-only scope, a new App Store product, no legacy migration, reference-based AI generation, high-likeness chibi style, and a twelve-intent core pack.
  - Deferred monetization at the product owner's request.
  - Wrote the detailed V1 product and implementation plan, including scope, user flow, domain model, architecture, AI pipeline, privacy, testing, phases, risks, and completion criteria.
  - Validated local links, Markdown fences, whitespace, decision consistency, and absence of API-like credentials in the new documentation.
  - Committed and pushed the detailed plan and persistent planning files to the existing documentation branch.
  - Updated draft PR #1 to describe the complete planning deliverable.
- Files created/modified:
  - `CONTEXT.md`
  - `docs/adr/0001-use-platform-native-sticker-delivery.md`
  - `docs/adr/0002-generate-reference-based-reaction-stickers.md`
  - `docs/adr/0003-relaunch-without-legacy-data-migration.md`
  - `docs/adr/0004-launch-as-a-new-app-store-product.md`
  - `.planning/personal-sticker-v1/task_plan.md`
  - `.planning/personal-sticker-v1/findings.md`
  - `.planning/personal-sticker-v1/progress.md`
  - `docs/product/personal-sticker-v1-plan.md`

- Published artifacts:
  - Branch: `codex/sticker-product-model`
  - Plan commit: `9ab254c Document personal sticker V1 plan`
  - Draft PR: `https://github.com/jackyrwj/StickerDiary/pull/1`

## Test Results

| Test | Input | Expected | Actual | Status |
|---|---|---|---|---|
| Documentation whitespace check | Current documentation branch | No malformed whitespace | `git diff --check` passed | Pass |
| Local documentation links | All relative links in detailed plan | Every target exists | Every target exists | Pass |
| Markdown fence balance | Detailed plan | Even number of fences | 8 fences | Pass |
| Documentation secret scan | Planning and product docs | No API-like credentials | No matches | Pass |
| Decision consistency review | Context, ADRs, and detailed plan | No contradictory scope | One wording conflict found and corrected | Pass |
| iOS Simulator build | `PersonalSticker` Debug scheme, iOS 17 minimum | App and Messages extension compile and embed | Build succeeded | Pass |
| Extension metadata | Built Messages extension `Info.plist` | Dynamic Messages extension and system media context declared | Required keys and both presentation contexts present | Pass |
| Source secret scan | New app and extension Swift sources | No client API credentials | No matches | Pass |
| Runtime UI and persistence | Booted iPhone simulator | Complete create/edit/save/relaunch flow | Creation, edit, save, favorite, relaunch, and deletion passed | Pass |
| Backend unit tests | Provider request, validation, and error fixtures | Contract is stable without real credentials | 5 of 5 tests passed | Pass |
| iOS-backend contract | Local fixture backend, twelve fixed reactions | iOS uploads normalized photos and renders returned images | Reached twelve-sticker review through backend mode | Pass |
| Real Alibaba generation | User mainland API key and native API URL | Generate one paid test image | One `received` image generated in 20.42 seconds; 886 × 1182 PNG, 1,487,420 bytes | Pass with quality follow-up |

## Error Log

| Timestamp | Error | Attempt | Resolution |
|---|---|---:|---|
| 2026-08-02 | None during planning-file initialization | 1 | No action required. |
| 2026-08-02 | ADR 0004 wording conflicted with the later decision to defer V1 monetization | 1 | Changed the ADR to refer only to any future in-app purchases. |
| 2026-08-02 | First extension compile used nonexistent `MSStickerSize.medium` | 1 | Replaced it with the SDK-defined `.regular` case. |
| 2026-08-02 | Second compile found an iOS 18-only symbol animation and an invalid Section initializer | 1 | Replaced them with iOS 17-compatible forms; also removed an unnecessary sendable closure annotation that produced a future Swift 6 warning. |
| 2026-08-02 | Simulator accessibility typing rejected Chinese characters | 1 | Recorded this as an automation-tool limitation and used ASCII text to verify the same caption replacement and local image re-render path. |
| 2026-08-02 | `simctl get_app_container` rejected the App Group identifier as a direct container argument | 1 | Switched to requesting the installed app's `groups` listing first, then resolving the exact shared-container path from that output. |
| 2026-08-02 | Final combined verification command had a shell-quoting parse error in its secret pattern | 1 | Split the secret scan into simple fixed expressions and reran the remaining checks without nested quote syntax. |
| 2026-08-02 | First real Alibaba one-image request returned HTTP 404 in 0.62 seconds, before any image result | 1 | Safely inspected URL structure without exposing credentials: it was the OpenAI-compatible `/compatible-mode/v1` route. Asked the owner to replace it with the region-specific workspace `/api/v1` URL before retrying. |
| 2026-08-02 | Second real request using the mainland native `/api/v1` route | 2 | Generated exactly one `received` image successfully in 20.42 seconds; no twelve-image batch was started. |

## 5-Question Reboot Check

| Question | Answer |
|---|---|
| Where am I? | Phase 2, with the modular app shell and offline mock vertical slice compiling successfully. |
| Where am I going? | Runtime vertical-slice verification, complete local domain behavior, real AI generation, system Stickers verification, and release hardening. |
| What's the goal? | Ship an iOS app that creates reusable personal reaction-sticker packs from reference photos. |
| What have I learned? | See `findings.md`. |
| What have I done? | Replaced the legacy diary target with the new modular personal-sticker app, local library, mock generator, and dynamic Messages extension. |

### Runtime verification: 2026-08-02

- Detected the user-booted iPhone 17 simulator running iOS 26.5.
- Built, installed, and launched the containing app successfully with its embedded Messages extension.
- Verified the production entry screen renders correctly, presents all twelve accepted reactions, and keeps generation disabled until a photo is available.
- Opened the system Photos picker and confirmed the imported test image is visible. The picker does not expose photo thumbnails as automation targets, so added a Debug-only `-UITestUseDemoPhoto` launch argument that supplies an existing bundled image; Release behavior is unchanged.
- Used the debug photo path to complete mock generation and reach the twelve-sticker review screen successfully.
- Verified caption editing re-renders the selected PNG and updates the review label; verified pack saving, favorite toggling, full process termination, relaunch, and favorite persistence.
- Found and fixed missing App Group entitlement keys in both targets. After rebuilding, iOS created `group.com.jackyrwj.PersonalSticker` and the app stored the manifest plus exactly 12 PNGs in that shared container.
- Verified saved output is 408 × 408 PNG; the largest test sticker is 102,930 bytes, safely below the 500 KB iMessage sticker limit.
- Verified iOS registers `com.jackyrwj.PersonalSticker.MessagesExtension` as a `com.apple.message-payload-provider` plugin and the Messages extension can decode the shared manifest shape.
- Opened a simulator Messages conversation and reached the system “贴纸” surface from its add menu; visual confirmation of the custom collection is the remaining extension-runtime check.
- Fixed the review screen's initial scroll position and made the caption editor open at full height. Rebuilt and runtime-verified that review starts at its heading and the caption field is immediately available to accessibility automation.
- Created a second pack, deleted it through the confirmation flow, and verified the manifest returned to one pack while shared PNG count returned from 24 to 12. Pack deletion cleans its files without damaging the remaining pack.

### Phase 3: Alibaba Cloud Model Studio integration

- **Status:** in progress
- The product owner selected Alibaba Cloud Model Studio (百炼).
- Confirmed against current official documentation that `wan2.7-image-pro` supports multi-image editing, Base64 data URLs, 1K editing output, and synchronous HTTP through a workspace-specific endpoint. Output URLs expire after 24 hours.
- Added a dependency-free Node.js backend with strict fixed-intent validation, server-owned prompts, private Base64 image forwarding, immediate result download, normalized errors, request-size limits, and no request-body logging.
- Added `backend/.env.example`; the real `DASHSCOPE_API_KEY` and workspace URL belong only in ignored `backend/.env`.
- Added five backend unit tests covering request construction, temporary-image download, rate-limit normalization, accepted private images, and rejection of arbitrary prompts. All five pass.
- Added an iOS backend generator selected only by the Debug launch argument `-StickerBackendURL`; without it, previews and normal development builds continue to use the deterministic local mock.
- Added client-side reference-image normalization to JPEG before upload and local 408 × 408 rendering of returned artwork before exact caption rendering.
- Regenerated the Xcode project, compiled successfully, and completed a simulator contract test against a local fixture backend. The iOS app sent all twelve fixed reaction requests through HTTP and reached the review screen without using a real API key.
- Made generation mode user-visible: backend mode now explicitly says selected photos are sent to the private backend and processed by Alibaba Cloud Model Studio; mock mode retains the local-only notice.
- Moved both App Group entitlement values into `project.yml` and verified project regeneration recreates them instead of erasing them.
- Added a manual one-image paid test command so the first credential check costs one generation instead of triggering the full twelve-image pack.
- Verified a launch without `-StickerBackendURL` still selects the local mock and displays the local-only privacy notice; backend and mock development modes remain isolated.
- Made local scripts ignore inherited DashScope variables before loading `backend/.env`, preventing an old shell credential from silently overriding the newly pasted key. Verified an empty local file produces a safe `503 configuration_required` health response without calling Alibaba.
- Completed the first paid one-image credential test with `/Users/raowenjie/Pictures/1000687065.JPG`. The image expresses “received” with a salute, but likeness is only moderate-to-low and the off-white output is effectively opaque despite carrying an alpha channel; prompt/background processing needs improvement before batch generation.
- Updated the product plan and ADR after owner review: identity-focused prompt changes will be A/B tested but are not accepted as a likeness guarantee; a user-approved one-image character anchor now gates pack generation. Automatic background removal, visible-subject cropping, safe padding, edge cleanup, and light/dark-background validation are explicit V1 requirements.
