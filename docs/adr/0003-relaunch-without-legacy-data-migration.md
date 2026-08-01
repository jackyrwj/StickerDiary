# Relaunch without legacy diary migration

The redesigned product will launch as a clean personal-sticker experience without migrating the current app's diaries, stickers, achievements, or diary-specific state. The product owner confirmed that the existing download and usage level does not justify carrying the old domain model, compatibility code, and migration risk into a fundamentally different product.

## Consequences

The redesign may replace legacy storage and remove the existing diary flows instead of preserving them behind an archive. Release communication must describe the product as a relaunch, and implementation must not spend effort maintaining behavior solely for the former diary model.
