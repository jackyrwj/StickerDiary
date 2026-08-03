# 贴贴生成后端

这个服务是 iOS App 与阿里云百炼之间的安全代理。百炼 Key 只存在于这里，不进入 Swift、App 安装包或 Git。

## 在哪里粘贴 Key

1. 在 `backend` 目录复制 `.env.example` 为 `.env`。
2. 打开 `backend/.env`。
3. 把 Key 粘贴在：

   ```text
   DASHSCOPE_API_KEY=你的真实Key
   ```

4. 把百炼业务空间 ID 填进 `DASHSCOPE_BASE_URL` 的 `YOUR_WORKSPACE_ID` 位置。Key 与业务空间必须属于同一地域。

`.env` 已被 Git 忽略。不要把真实 Key 写进 `.env.example`，也不要把 `.env` 手动加入 Git。

## 本地启动

需要 Node.js 20.6 或更新版本：

```bash
cd backend
cp .env.example .env
npm run start:local
```

服务默认运行在 `http://127.0.0.1:8787`。可先访问 `/health` 检查配置是否完整。

本地命令会明确使用这个 `.env`，避免终端里遗留的旧环境变量覆盖你刚粘贴的新 Key。将来部署到服务器时才使用 `npm start` 和服务器的加密环境变量。

## 第一次真实测试：只生成一张

不要先在 App 中生成整套，否则会连续调用 12 次。填好 `.env` 后，先执行：

```bash
npm run test:aliyun -- /你的测试照片绝对路径.jpg
```

这只会调用一次“收到”贴纸。成功结果保存在 `backend/.local-test-output.png`（或 `.jpg`），该文件同样不会进入 Git。先检查相似度和表情语义，再决定是否生成整套。

要让模拟器使用真实后端，在 App 启动参数中加入：

```text
-StickerBackendURL http://127.0.0.1:8787
```

没有这个调试参数时，App 继续使用不收费的本地模拟生成器。正式发布前会把地址改为 HTTPS 线上服务，并增加 App Attest、限流和任务恢复。

## 当前接口

`POST /v1/stickers/generate` 一次生成一个固定聊天意图。客户端只发送 1–4 张参考图和 `reactionId`；提示词由后端固定模板生成，客户端不能注入任意提示词。

服务不把参考照片写入磁盘，不记录请求正文，并会立即下载百炼返回的临时结果 URL。百炼临时结果地址不会返回给 iOS。
