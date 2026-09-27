# sticker-diary-proxy

Cloudflare Worker that forwards overseas diary requests to Model Studio
(Singapore) so the international API key never ships in the app.

## Deploy

```bash
cd proxy
npx wrangler login
npx wrangler secret put DASHSCOPE_API_KEY   # Singapore-region Model Studio key
npx wrangler secret put APP_TOKEN           # value of proxyAppToken in MilkTeaStickerView.swift
npx wrangler deploy
```

Then set `proxyEndpoint` in `BailianDiaryGenerator` to
`https://<worker-url>/v1/chat/completions`.

Guards: `X-App-Token` check, model allowlist (`ALLOWED_MODELS`), 6 requests
per minute per IP, 6 MB body limit, `max_tokens` capped at 4000.
Mainland users (device region CN) still call the mainland endpoint directly.
