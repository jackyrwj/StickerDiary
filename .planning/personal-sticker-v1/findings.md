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

## Research Findings

- Apple supports dynamic sticker experiences through Messages and the system Stickers surface.
- Apple documents that a coded iMessage extension can provide a runtime-changing collection through `MSStickerBrowserViewController`. By declaring the media presentation context, the extension can appear in the system Stickers app accessible from the emoji keyboard; this is the appropriate path for user-generated packs. A no-code Sticker Pack target is static and is not sufficient for this product.
- Apple requires advertising to stay in the main app binary and outside extensions; monetization is deferred for V1 regardless.
- Reference-image models from Alibaba, Google, and OpenAI support image editing and varying degrees of character consistency; provider selection requires a controlled benchmark.
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

## Issues and Risks

| Issue | Planned response |
|---|---|
| One photo may not preserve identity reliably | Accept up to four references and request more when likeness confidence is low. |
| Twelve independent generations may drift in style or identity | Create a reusable character anchor and feed it into every reaction generation. |
| AI may render broken Chinese text | Generate art without text and render captions locally. |
| Partial generation failure can waste time and cost | Model each reaction as an independent attempt with resumable job state. |
| System extension cannot depend on network availability | Copy only approved local sticker files into the shared container. |
| User photos are sensitive | Require explicit consent, document retention, minimize upload scope, and support deletion. |
| New app category is crowded | The product must demonstrate personal identity preservation and system reuse, not generic AI art. |
| ADR 0004 originally implied V1 required in-app purchases | Clarified that only future in-app purchases would belong to the new App Store product; monetization remains deferred. |

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
