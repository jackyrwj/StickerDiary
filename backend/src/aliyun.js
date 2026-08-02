import { validateProviderConfig } from "./config.js";
import { buildStickerPrompt } from "./prompt.js";

const generationPath = "/services/aigc/multimodal-generation/generation";
const maxOutputBytes = 20 * 1024 * 1024;

export async function generateWithAliyun({ config, request, fetchImpl = fetch }) {
  validateProviderConfig(config);

  const content = request.referenceImages.map(({ dataURL }) => ({ image: dataURL }));
  content.push({ text: buildStickerPrompt(request.reactionId) });

  const response = await fetchImpl(`${config.baseURL}${generationPath}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: config.model,
      input: {
        messages: [{ role: "user", content }],
      },
      parameters: {
        size: "1K",
        n: 1,
        watermark: false,
      },
    }),
    signal: AbortSignal.timeout(180_000),
  });

  const providerBody = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new ProviderError(
      providerBody.message || `百炼请求失败（HTTP ${response.status}）`,
      response.status === 429 || response.status >= 500,
    );
  }

  const output = providerBody.output?.choices?.flatMap(
    (choice) => choice.message?.content ?? [],
  ).find((item) => item.type === "image" && typeof item.image === "string");
  if (!output) {
    throw new ProviderError(providerBody.message || "百炼没有返回图片", false);
  }

  const imageResponse = await fetchImpl(output.image, {
    signal: AbortSignal.timeout(60_000),
  });
  if (!imageResponse.ok) {
    throw new ProviderError("生成图片下载失败", true);
  }

  const mimeType = imageResponse.headers.get("content-type")?.split(";")[0] ?? "image/png";
  if (!mimeType.startsWith("image/")) {
    throw new ProviderError("百炼返回了非图片内容", false);
  }
  const imageBytes = Buffer.from(await imageResponse.arrayBuffer());
  if (imageBytes.length === 0 || imageBytes.length > maxOutputBytes) {
    throw new ProviderError("生成图片大小异常", false);
  }

  return {
    imageBase64: imageBytes.toString("base64"),
    mimeType,
    providerRequestId: providerBody.request_id ?? providerBody.requestId ?? null,
  };
}

export class ProviderError extends Error {
  constructor(message, retryable) {
    super(message);
    this.name = "ProviderError";
    this.retryable = retryable;
  }
}
