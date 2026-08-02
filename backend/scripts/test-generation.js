import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { generateWithAliyun } from "../src/aliyun.js";
import { loadConfig } from "../src/config.js";

const imagePath = process.argv[2];
if (!imagePath) {
  console.error("用法：npm run test:aliyun -- /图片/绝对路径.jpg");
  process.exitCode = 1;
} else {
  const image = await readFile(imagePath);
  const mimeType = mimeTypeForPath(imagePath);
  const result = await generateWithAliyun({
    config: loadConfig(),
    request: {
      referenceImages: [{
        dataURL: `data:${mimeType};base64,${image.toString("base64")}`,
      }],
      reactionId: "received",
    },
  });

  const extension = result.mimeType === "image/jpeg" ? "jpg" : "png";
  const outputPath = path.resolve(`.local-test-output.${extension}`);
  await writeFile(outputPath, Buffer.from(result.imageBase64, "base64"));
  console.log(`单张百炼测试成功：${outputPath}`);
}

function mimeTypeForPath(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
  case ".jpg":
  case ".jpeg":
    return "image/jpeg";
  case ".webp":
    return "image/webp";
  case ".png":
    return "image/png";
  default:
    throw new Error("测试图片只支持 PNG、JPEG 或 WEBP");
  }
}
