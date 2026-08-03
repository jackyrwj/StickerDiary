import assert from "node:assert/strict";
import test from "node:test";
import { generateWithAliyun, ProviderError } from "../src/aliyun.js";

const config = {
  apiKey: "test-key",
  baseURL: "https://workspace.cn-beijing.maas.aliyuncs.com/api/v1",
  model: "wan2.7-image-pro",
  port: 8787,
};

test("builds the Wan 2.7 request and downloads the temporary image", async () => {
  const calls = [];
  const fetchImpl = async (url, options = {}) => {
    calls.push({ url, options });
    if (calls.length === 1) {
      return new Response(JSON.stringify({
        request_id: "request-1",
        output: {
          choices: [{ message: { content: [{ type: "image", image: "https://result/image.png" }] } }],
        },
      }), { status: 200, headers: { "content-type": "application/json" } });
    }
    return new Response(Buffer.from("fake-png"), {
      status: 200,
      headers: { "content-type": "image/png" },
    });
  };

  const result = await generateWithAliyun({
    config,
    request: {
      referenceImages: [{ dataURL: "data:image/png;base64,YQ==" }],
      reactionId: "received",
    },
    fetchImpl,
  });

  assert.equal(calls.length, 2);
  assert.equal(calls[0].options.headers.Authorization, "Bearer test-key");
  const providerRequest = JSON.parse(calls[0].options.body);
  assert.equal(providerRequest.model, "wan2.7-image-pro");
  assert.equal(providerRequest.parameters.size, "1K");
  assert.equal(providerRequest.parameters.watermark, false);
  assert.match(providerRequest.input.messages[0].content.at(-1).text, /不要生成任何文字/);
  assert.match(providerRequest.input.messages[0].content.at(-1).text, /不要变成通用大眼萌脸/);
  assert.equal(result.imageBase64, Buffer.from("fake-png").toString("base64"));
  assert.equal(result.providerRequestId, "request-1");
});

test("normalizes provider failures without leaking the key", async () => {
  const fetchImpl = async () => new Response(JSON.stringify({ message: "限流" }), {
    status: 429,
    headers: { "content-type": "application/json" },
  });

  await assert.rejects(
    generateWithAliyun({
      config,
      request: {
        referenceImages: [{ dataURL: "data:image/png;base64,YQ==" }],
        reactionId: "received",
      },
      fetchImpl,
    }),
    (error) => error instanceof ProviderError && error.retryable === true,
  );
});
