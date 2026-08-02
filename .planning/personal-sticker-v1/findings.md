# Findings and Decisions: AI Personal Sticker V1

## Requirements

- Build a new native iOS product rather than continuing the diary experience.
- Turn one to four reference photos into a recognizable chibi sticker character.
- Generate a curated pack of twelve semantically meaningful reaction stickers.
- Let users review, delete, edit captions, and regenerate individual stickers.
- Store approved packs locally and expose them through the iOS system Stickers experience.
- Exclude Android, legacy migration, accounts, ads, subscriptions, and in-app purchases from V1.
- Preserve the plan and decisions in repository documentation so future sessions do not lose context.

## Repository Findings

- The current app targets iOS 17 and is implemented in SwiftUI.
- `MilkTeaStickerView.swift` is approximately 12,000 lines and combines UI, navigation, persistence, networking, camera, image processing, achievements, diary editing, and settings.
- The existing app already performs on-device foreground extraction with Vision and renders bordered transparent stickers.
- The current storage keeps only the newest fifty stickers, which is incompatible with a lasting personal sticker library.
- The working `main` checkout contains extensive uncommitted user changes and is one commit ahead of `origin/main`; implementation must use an isolated branch/worktree.
- A live-looking Bailian API credential is embedded in the current client source. It must be revoked and must not be copied into the new product.
- Runtime code-signature inspection found that merely declaring entitlement-file paths in the generated Xcode project is insufficient when those plist files contain no keys. Both binaries must carry the identical `com.apple.security.application-groups` value or the repository silently falls back to the containing app's Documents directory and the extension sees no stickers.

## Research Findings

- Apple supports dynamic sticker experiences through Messages and the system Stickers surface.
- Apple documents that a coded iMessage extension can provide a runtime-changing collection through `MSStickerBrowserViewController`. By declaring the media presentation context, the extension can appear in the system Stickers app accessible from the emoji keyboard; this is the appropriate path for user-generated packs. A no-code Sticker Pack target is static and is not sufficient for this product.
- Apple requires advertising to stay in the main app binary and outside extensions; monetization is deferred for V1 regardless.
- Reference-image models from Alibaba, Google, and OpenAI support image editing and varying degrees of character consistency; provider selection requires a controlled benchmark.
- The product owner selected Alibaba Cloud Model Studio (百炼) as the first production provider. Current official guidance uses the `DASHSCOPE_API_KEY` environment variable; the key is region-specific and must never be placed in Swift or committed files.
- Current Wan image-editing guidance recommends `wan2.7-image-pro` for multi-image editing and subject-feature preservation. It accepts one to four private images as Base64 data URLs in `messages[].content`, supports synchronous HTTP at the workspace-specific Beijing `/services/aigc/multimodal-generation/generation` endpoint, and returns temporary image URLs that expire after 24 hours. The backend must download the output immediately.
- The current Wan 2.7 edit API accepts `1K` output for editing. This is sufficient because the iOS client normalizes final stickers to 408 × 408 PNG.
- Alibaba's current console guidance says the workspace ID can be copied from the upper-right workspace control on the Model Studio console home page after selecting the target region. Beijing and several other regions require the workspace ID in the base URL; workspace-specific domains are the recommended production endpoint, while the older DashScope domain remains mainly for compatibility.
- The first real call reached an HTTP 404 before generation because `DASHSCOPE_BASE_URL` pointed to the OpenAI-compatible `/compatible-mode/v1` API. The owner's mainland key successfully generated through the native mainland public endpoint ending in `/api/v1`; keep workspace-specific URLs as the documented production preference rather than a prerequisite for this account.
- The first `wan2.7-image-pro` portrait test completed in 20.42 seconds and returned an 886 × 1182 PNG (1,487,420 bytes). It clearly communicated “received” through a salute and retained hair, black shirt, and watch, but facial identity was generalized into a common chibi face. The background looked off-white and its alpha ranged only from 0.992 to 1.0, so it is functionally opaque and requires background removal before sticker export.
- Apple permits renaming an app, but the accepted plan is to use a new App Store record and bundle identifier because the product is fundamentally different.

## Technical Decisions

| Decision | Rationale |
|---|---|
| SwiftUI with modern iOS 17 state management | Matches the current platform baseline and supports a modular native implementation. |
| Small feature-focused views and injected services | Prevents recreating the current monolithic view and keeps mock/real services interchangeable. |
| Local metadata database plus file-backed images | Image blobs remain outside preference storage and can be shared or cleaned independently. |
| App Group for approved extension assets | The containing app and sticker extension need a supported shared container. |
| Provider-neutral server API | Keeps credentials off-device and reduces model lock-in. |
| Mock generation path from the first build | Enables deterministic previews, tests, simulator work, and UI progress before paid cloud calls. |
| Deterministic local sticker cleanup | Automatically remove nontransparent backgrounds, crop the visible subject with safe padding, and validate edges on light and dark backgrounds instead of trusting model transparency. |

## Issues and Risks

| Issue | Planned response |
|---|---|
| One photo may not preserve identity reliably | Accept up to four references and request more when likeness confidence is low. |
| Stronger identity wording may still produce a generic chibi face | A/B test prompt constraints, but rely on multiple references plus review and single-sticker regeneration rather than repeated prompt-only retries. |
| Twelve independent generations may drift in style or identity | Create a reusable character anchor and feed it into every reaction generation. |
| AI may render broken Chinese text | Generate art without text and render captions locally. |
| Partial generation failure can waste time and cost | Model each reaction as an independent attempt with resumable job state. |
| System extension cannot depend on network availability | Copy only approved local sticker files into the shared container. |
| User photos are sensitive | Require explicit consent, document retention, minimize upload scope, and support deletion. |
| New app category is crowded | The product must demonstrate personal identity preservation and system reuse, not generic AI art. |
| ADR 0004 originally implied V1 required in-app purchases | Clarified that only future in-app purchases would belong to the new App Store product; monetization remains deferred. |
| A separate anchor confirmation would add friction to the main flow | The owner rejected it; generate directly from selected references and handle likeness corrections during review. |

- Apple Vision's iOS 17 foreground-instance mask request returns individual foreground instances. Its observation can create a high-resolution masked image with all unselected pixels transparent and optionally crop to the smallest extent containing the selected instances, which fits the required on-device cleanup pipeline.
- Vision did not remove the first Wan result's lightly textured off-white background by itself; it effectively preserved the portrait rectangle. A border-connected color cleanup after Vision removed only background regions connected to the image edges and produced a 408 × 408 PNG with all four corners transparent, visible bounds 194 × 312 at +107,+18, and a 105,989-byte base asset.

## Resources

- `CONTEXT.md`
- `docs/adr/0001-use-platform-native-sticker-delivery.md`
- `docs/adr/0002-generate-reference-based-reaction-stickers.md`
- `docs/adr/0003-relaunch-without-legacy-data-migration.md`
- `docs/adr/0004-launch-as-a-new-app-store-product.md`
- Apple Messages documentation: https://developer.apple.com/documentation/messages
- Apple dynamic sticker browser: https://developer.apple.com/documentation/messages/msstickerbrowserviewcontroller
- Apple system Stickers presentation contexts: https://developer.apple.com/documentation/messages/adding-sticker-packs-and-imessage-apps-to-the-system-stickers-app-messages-camera-and-facetime
- App Store Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- Alibaba image models: https://help.aliyun.com/zh/model-studio/image-model/
- Gemini image generation: https://ai.google.dev/gemini-api/docs/image-generation

## Open Decisions

- Product name, icon, and final App Store category.
- Backend host and first production image model.
- Exact storage technology after a short prototype comparison.
- iCloud sync timing.
- Analytics approach and privacy-preserving activation metrics.
- Reference-image retention window and deletion guarantee.
