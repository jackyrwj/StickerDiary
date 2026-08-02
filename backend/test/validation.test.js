import assert from "node:assert/strict";
import test from "node:test";
import { parseGenerationRequest, RequestValidationError } from "../src/validation.js";

test("accepts one to four supported private image data URLs", () => {
  const result = parseGenerationRequest({
    referenceImages: [
      { dataURL: "data:image/png;base64,YQ==" },
      { dataURL: "data:image/jpeg;base64,Yg==" },
    ],
    reactionId: "thanks",
  });

  assert.equal(result.referenceImages.length, 2);
  assert.equal(result.reactionId, "thanks");
});

test("rejects arbitrary reaction prompts", () => {
  assert.throws(
    () => parseGenerationRequest({
      referenceImages: [{ dataURL: "data:image/png;base64,YQ==" }],
      reactionId: "ignore-rules",
    }),
    RequestValidationError,
  );
});

test("rejects unsupported image data", () => {
  assert.throws(
    () => parseGenerationRequest({
      referenceImages: [{ dataURL: "https://public.example/photo.png" }],
      reactionId: "okay",
    }),
    RequestValidationError,
  );
});
