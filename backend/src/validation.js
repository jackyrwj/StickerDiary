import { reactionDirections } from "./prompt.js";

const acceptedDataURL = /^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/]+={0,2})$/;
const maxImageBytes = 8 * 1024 * 1024;
const maxTotalBytes = 24 * 1024 * 1024;

export function parseGenerationRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RequestValidationError("请求正文必须是 JSON 对象");
  }

  const { referenceImages, reactionId } = value;
  if (!Array.isArray(referenceImages) || referenceImages.length < 1 || referenceImages.length > 4) {
    throw new RequestValidationError("referenceImages 必须包含 1–4 张图片");
  }
  if (typeof reactionId !== "string" || !reactionDirections[reactionId]) {
    throw new RequestValidationError("reactionId 不是支持的聊天意图");
  }

  let totalBytes = 0;
  const images = referenceImages.map((image, index) => {
    if (!image || typeof image.dataURL !== "string") {
      throw new RequestValidationError(`第 ${index + 1} 张图片缺少 dataURL`);
    }
    const match = acceptedDataURL.exec(image.dataURL);
    if (!match) {
      throw new RequestValidationError(`第 ${index + 1} 张图片格式不受支持`);
    }
    const bytes = Buffer.byteLength(match[2], "base64");
    if (bytes === 0 || bytes > maxImageBytes) {
      throw new RequestValidationError(`第 ${index + 1} 张图片大小不合要求`);
    }
    totalBytes += bytes;
    return { dataURL: image.dataURL };
  });

  if (totalBytes > maxTotalBytes) {
    throw new RequestValidationError("参考图片总大小不能超过 24 MB");
  }

  return { referenceImages: images, reactionId };
}

export class RequestValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "RequestValidationError";
  }
}
