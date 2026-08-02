const DEFAULT_MODEL = "wan2.7-image-pro";

export function loadConfig(environment = process.env) {
  const baseURL = environment.DASHSCOPE_BASE_URL?.replace(/\/+$/, "");

  return {
    apiKey: environment.DASHSCOPE_API_KEY?.trim() ?? "",
    baseURL: baseURL?.trim() ?? "",
    model: environment.DASHSCOPE_MODEL?.trim() || DEFAULT_MODEL,
    port: parsePort(environment.PORT),
  };
}

export function validateProviderConfig(config) {
  if (!config.apiKey) {
    throw new ConfigurationError("缺少 DASHSCOPE_API_KEY");
  }
  if (!config.baseURL) {
    throw new ConfigurationError("缺少 DASHSCOPE_BASE_URL");
  }

  let url;
  try {
    url = new URL(config.baseURL);
  } catch {
    throw new ConfigurationError("DASHSCOPE_BASE_URL 不是有效地址");
  }
  if (url.protocol !== "https:") {
    throw new ConfigurationError("DASHSCOPE_BASE_URL 必须使用 HTTPS");
  }
  if (config.baseURL.includes("YOUR_WORKSPACE_ID")) {
    throw new ConfigurationError("请在 DASHSCOPE_BASE_URL 中填写业务空间 ID");
  }
}

function parsePort(value) {
  const port = Number.parseInt(value ?? "8787", 10);
  return Number.isInteger(port) && port > 0 && port <= 65535 ? port : 8787;
}

export class ConfigurationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ConfigurationError";
  }
}
