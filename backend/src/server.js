import http from "node:http";
import { fileURLToPath } from "node:url";
import { generateWithAliyun, ProviderError } from "./aliyun.js";
import { ConfigurationError, loadConfig, validateProviderConfig } from "./config.js";
import { parseGenerationRequest, RequestValidationError } from "./validation.js";

const maxRequestBytes = 34 * 1024 * 1024;

export function createServer({ config = loadConfig(), generate = generateWithAliyun } = {}) {
  return http.createServer(async (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("Content-Type", "application/json; charset=utf-8");

    if (request.method === "GET" && request.url === "/health") {
      try {
        validateProviderConfig(config);
        sendJSON(response, 200, { status: "ok", provider: "aliyun", model: config.model });
      } catch (error) {
        sendJSON(response, 503, {
          status: "configuration_required",
          message: error.message,
        });
      }
      return;
    }

    if (request.method === "POST" && request.url === "/v1/stickers/generate") {
      try {
        const body = await readJSON(request);
        const generationRequest = parseGenerationRequest(body);
        const result = await generate({ config, request: generationRequest });
        sendJSON(response, 200, result);
      } catch (error) {
        handleError(response, error);
      }
      return;
    }

    sendJSON(response, 404, {
      error: { code: "not_found", message: "接口不存在", retryable: false },
    });
  });
}

async function readJSON(request) {
  const contentType = request.headers["content-type"] ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new RequestValidationError("Content-Type 必须是 application/json");
  }

  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxRequestBytes) {
      throw new RequestValidationError("请求正文过大");
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RequestValidationError("请求正文不是有效 JSON");
  }
}

function handleError(response, error) {
  if (error instanceof RequestValidationError) {
    sendJSON(response, 400, {
      error: { code: "invalid_request", message: error.message, retryable: false },
    });
    return;
  }
  if (error instanceof ConfigurationError) {
    sendJSON(response, 503, {
      error: { code: "configuration_required", message: error.message, retryable: false },
    });
    return;
  }
  if (error instanceof ProviderError) {
    sendJSON(response, 502, {
      error: { code: "provider_error", message: error.message, retryable: error.retryable },
    });
    return;
  }

  console.error("generation_failed", error instanceof Error ? error.name : "UnknownError");
  sendJSON(response, 500, {
    error: { code: "internal_error", message: "生成服务暂时不可用", retryable: true },
  });
}

function sendJSON(response, statusCode, body) {
  response.statusCode = statusCode;
  response.end(JSON.stringify(body));
}

const isMainModule = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMainModule) {
  const config = loadConfig();
  const server = createServer({ config });
  server.listen(config.port, "127.0.0.1", () => {
    console.log(`personal-sticker-backend listening on http://127.0.0.1:${config.port}`);
  });
}
