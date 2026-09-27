// Forwards diary requests from the app to Model Studio, adding the API key on
// the server side. Only chat completions for the allowed vision models pass.

const MAX_BODY_BYTES = 6 * 1024 * 1024;
const MAX_TOKENS_CAP = 4000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return json({ error: "not_found" }, 404);
    }
    if (!env.APP_TOKEN || request.headers.get("X-App-Token") !== env.APP_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }

    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.DIARY_LIMITER.limit({ key: ip });
    if (!success) return json({ error: "rate_limited" }, 429);

    const length = Number(request.headers.get("Content-Length") ?? 0);
    if (length > MAX_BODY_BYTES) return json({ error: "too_large" }, 413);

    let body;
    try {
      const raw = await request.text();
      if (raw.length > MAX_BODY_BYTES) return json({ error: "too_large" }, 413);
      body = JSON.parse(raw);
    } catch {
      return json({ error: "bad_request" }, 400);
    }

    const allowed = env.ALLOWED_MODELS.split(",");
    if (!allowed.includes(body.model) || !Array.isArray(body.messages)) {
      return json({ error: "model_not_allowed" }, 400);
    }
    body.stream = false;
    body.max_tokens = Math.min(Number(body.max_tokens) || 1200, MAX_TOKENS_CAP);

    const upstream = await fetch(env.UPSTREAM_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.DASHSCOPE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "Content-Type": upstream.headers.get("Content-Type") ?? "application/json" },
    });
  },
};

function json(value, status) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
