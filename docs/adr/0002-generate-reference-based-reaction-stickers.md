# Generate reference-based reaction stickers

The product will use reference-image editing to generate poses and expressions that communicate specific conversational intents, rather than merely decorating one cutout or generating an unrelated character from text. The default result will be a high-likeness chibi sticker character: recognizable enough to feel personal, but stylized enough to support exaggerated reactions without the uncanny appearance of edited photorealistic faces.

## Consequences

Sticker text remains a separate local rendering layer so wording is accurate and editable. Generation must preserve a reusable character identity across a pack, allow additional reference photos when one photo is insufficient, and keep the image-model provider replaceable.
