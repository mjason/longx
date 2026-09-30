# Longx

[简体中文](README.md) · **English** · [日本語](README.ja.md)

**Put an AI coding agent to work in your project.** Longx is a local-first workspace that brings agent sessions, files, terminal commands, and Git into one interface. Connect your own model provider and tailor agent behavior per project.

![Longx project home](docs/media/welcome.png)

<details>
<summary>Workspace screenshots</summary>

![Session workspace](docs/media/session.png)

![File tree](docs/media/files.png)

![File browser and Markdown preview](docs/media/file-preview.png)

</details>

**Video tours:** [▶ Desktop tour](docs/media/tour.webm) · [▶ Mobile tour](docs/media/tour-mobile.webm)

Mobile screenshots: [project home](docs/media/welcome-mobile.png) · [workspace](docs/media/session-mobile.png)

## Highlights

- **Bring your own model:** DeepSeek, GLM, Alibaba Cloud Bailian, OpenAI, or any provider compatible with the OpenAI Responses API.
- **Work in the real project:** agents can read and edit files, run commands, and inspect Git changes. Sessions and the file tree share one workspace.
- **Customize per project:** define agent instructions, plugs, sub-agents, and knowledge in `.longx/`.
- **Desktop and mobile:** responsive web UI, with an Android WebView shell available.

> **Security:** Longx does not sandbox agent commands. Commands run with the operating-system permissions of the Longx process. Use it with projects you trust, or isolate the whole deployment in a container or equivalent environment.

## Quick start

On Linux x86_64 or arm64, install the packaged release:

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

Open `http://<host>:7788`, then configure a model under **Settings → Providers**. You can also download a package from [Releases](https://github.com/mjason/longx/releases) or start with [Docker Compose](docker-compose.yml).

For development, see the [Chinese README](README.md#启动开发) and its full installation, HTTPS, upgrade, Docker, model, and architecture notes. The application UI currently supports Simplified Chinese and English; this page is also available in Japanese.
