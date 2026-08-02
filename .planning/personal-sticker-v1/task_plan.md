# Task Plan: AI Personal Sticker V1

## Goal

Deliver a new native iOS app that turns reference photos into a reusable, high-likeness chibi reaction-sticker pack and makes that pack available through the iOS system Stickers experience.

## Next Step

Implement the provider-neutral backend contract and an Alibaba Cloud Model Studio adapter, then connect the iOS generator to that backend without shipping the API key in the app.

## Current Phase

Phase 3 — AI generation pipeline

## Phases

### Phase 0: Product and implementation planning

- [x] Audit the existing Sticker Diary codebase and App Store positioning.
- [x] Resolve the primary product direction through the product interview.
- [x] Record the domain language and hard-to-reverse decisions.
- [x] Complete the detailed V1 plan.
- [x] Validate the detailed V1 plan against the glossary and ADRs.
- [x] Review the detailed V1 plan with the product owner.
- [x] Resolve blocking open decisions and confirm shared understanding.
- **Status:** complete

### Phase 1: Safe project scaffolding

- [x] Create a dedicated implementation branch and isolated worktree.
- [x] Establish a new modular SwiftUI app shell and sticker extension target.
- [x] Add mock services, previews, routing, dependency injection, and build verification.
- [x] Remove all client-side API credentials from the new product.
- **Status:** complete

### Phase 2: Local sticker domain and library

- [ ] Implement sticker characters, reference photos, packs, reaction stickers, and generation jobs.
- [x] Store metadata locally and image assets as files.
- [ ] Build character creation, pack library, favorites, recent items, and deletion.
- [x] Verify persistence, relaunch behavior, empty states, and storage cleanup.
- **Status:** in_progress

### Phase 3: AI generation pipeline

- [x] Define the provider-neutral backend contract. (Alibaba Cloud Model Studio is the first provider; iOS only sees the app-owned single-sticker endpoint.)
- [ ] Implement a secure server-side image-model adapter and generation job lifecycle. (The secure adapter is implemented; persistent jobs, public-service authentication, and recovery remain.)
- [ ] Benchmark candidate models with a fixed likeness and reaction test set.
- [ ] Integrate real generation, partial failure recovery, moderation, cancellation, and retry. (The iOS backend path, normalized errors, and one-image credential test are complete; remaining lifecycle states are pending.)
- **Status:** pending

### Phase 4: Core reaction-pack workflow

- [x] Generate the twelve accepted conversational intents in the mock flow.
- [x] Render exact editable Chinese captions locally.
- [ ] Build review, delete, caption edit, and single-sticker regeneration flows. (Review, delete, and caption editing are implemented and runtime-verified; single-sticker regeneration remains.)
- [ ] Validate transparency, visual consistency, file size, and accessibility descriptions.
- **Status:** pending

### Phase 5: iOS system Stickers integration

- [x] Share approved sticker assets through an App Group.
- [x] Implement dynamic presentation of user-created stickers with a Messages extension.
- [ ] Verify install, refresh, deletion, upgrade, and no-network reuse behavior.
- [ ] Keep all advertising, purchasing, and marketing out of the extension.
- **Status:** pending

### Phase 6: Hardening and release readiness

- [ ] Add unit, integration, UI, failure-path, performance, accessibility, and privacy tests.
- [ ] Finalize product name, icon, privacy policy, App Store metadata, and review notes.
- [ ] Run a bounded TestFlight validation and evaluate the success metrics.
- [ ] Prepare the new App Store record while leaving Sticker Diary only removed from sale.
- **Status:** pending

## Key Questions

1. Which production host will run the backend after the local Alibaba Cloud Model Studio integration is validated?
2. What is the final product name and visual identity?
3. Is V1 entirely local apart from AI generation, or should iCloud sync be included?
4. Which reference-photo retention and server-deletion policy will be promised to users?
5. What objective threshold defines acceptable character likeness and generation latency?

## Decisions Made

| Decision | Rationale |
|---|---|
| Replace diary-first journaling with reusable personal reaction stickers | Reuse in existing conversations offers a more credible high-frequency behavior. |
| Launch only on iOS initially | The repository is native iOS and Apple provides the strongest system sticker surface. |
| Launch as a new App Store product | The new purpose, data model, privacy boundary, and brand differ fundamentally from Sticker Diary. |
| Do not migrate legacy diary data | The existing installed base does not justify carrying the former domain and compatibility cost. |
| Use reference-image editing and high-likeness chibi output | It can express real reactions while avoiding the uncanny quality of photorealistic facial edits. |
| Generate a curated twelve-intent core pack without a prompt box | It produces immediate conversational utility and avoids asking users to design their own product experience. |
| Add captions locally, outside the image model | Chinese text remains exact, editable, accessible, and consistently styled. |
| Use a backend proxy for cloud AI | API secrets must never ship in the iOS binary and the model provider must remain replaceable. |
| Use Alibaba Cloud Model Studio `wan2.7-image-pro` as the first image provider candidate | The owner already has Model Studio access, and the current model supports multi-image editing and subject-feature preservation. |
| Defer ads, subscriptions, and in-app purchases | The product owner asked to validate and finish the core app before monetization. |

## Errors Encountered

| Error | Attempt | Resolution |
|---|---:|---|
| `MSStickerSize.medium` does not exist | 1 | Used the SDK-defined `.regular` case, which Apple describes as the medium display size. |
| iOS 17 compile rejected iOS 18 `breathe` symbol effect and shorthand Section header/footer syntax | 1 | Switched to the iOS 17 `pulse` effect and the explicit Section content/header/footer initializer. |
| Runtime install had no App Group entitlements, so the extension could not read app-created stickers | 1 | Added the shared application-group entitlement to both the containing app and Messages extension, then required a second runtime verification pass. |
| Xcode could not find the new backend generator source | 1 | The generated project had not been refreshed after adding a new Swift file; regenerate it from `project.yml` before rebuilding. |
| Regenerating the Xcode project erased the manually populated App Group entitlement files | 1 | Move the App Group values into `project.yml` entitlement properties so every regeneration recreates both files correctly. |
| Node 26 test discovery executed the manual paid-test script, and the secret scan matched a documentation placeholder | 1 | Restrict unit tests to `test/*.test.js` and remove the key-shaped prefix from documentation examples. |
| First real Alibaba one-image request returned HTTP 404 before generation | 1 | The configured URL was the OpenAI-compatible `/compatible-mode/v1` route. Changing to the mainland native `/api/v1` route succeeded on the next, non-identical request. |

## Notes

- Re-read this plan before every implementation phase and after context recovery.
- Update `findings.md` after research and `progress.md` after each meaningful change or test.
- Never modify the user's dirty `main` worktree directly.
- The detailed scope and acceptance criteria live in `docs/product/personal-sticker-v1-plan.md`.
