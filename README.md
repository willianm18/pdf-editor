<p align="center">
  <img src="https://raw.githubusercontent.com/Stirling-Tools/Stirling-PDF/main/docs/stirling.png" width="80" alt="Stirling PDF logo">
</p>

<h1 align="center">Stirling PDF - The Open-Source PDF Platform</h1>

Stirling PDF is a powerful, open-source PDF editing platform. Run it as a personal desktop app, in the browser, or deploy it on your own servers with a private API. Edit, sign, redact, convert, and automate PDFs without sending documents to external services.

<p align="center">
  <a href="https://hub.docker.com/r/stirlingtools/stirling-pdf">
    <img src="https://img.shields.io/docker/pulls/frooodle/s-pdf" alt="Docker Pulls">
  </a>
  <a href="https://discord.gg/HYmhKj45pU">
    <img src="https://img.shields.io/discord/1068636748814483718?label=Discord" alt="Discord">
  </a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/Stirling-Tools/Stirling-PDF">
    <img src="https://api.scorecard.dev/projects/github.com/Stirling-Tools/Stirling-PDF/badge" alt="OpenSSF Scorecard">
  </a>
  <a href="https://github.com/Stirling-Tools/stirling-pdf">
    <img src="https://img.shields.io/github/stars/stirling-tools/stirling-pdf?style=social" alt="GitHub Repo stars">
  </a>
</p>

![Stirling PDF - Dashboard](images/home-light.png)

## This Fork: Real AI Background Removal (rembg)

This fork replaces the naive color-key "Remove white background (make transparent)"
checkbox (image editor screen) with real AI-based background removal powered by
[rembg](https://github.com/danielgatis/rembg). Instead of just clearing pixels
close to white, it detects and removes the actual subject's background — works on
photos, gradients, and complex backgrounds, not just solid white.

How it works: the checkbox now sends the image to a new backend endpoint
(`POST /api/v1/misc/remove-image-background`), which forwards it to a `rembg`
container running the `u2net` model and returns a transparent PNG.

**Deploying this fork:**

- `docker-compose.yml` — local/dev: builds the `stirling-pdf` image from source and
  the `rembg` image from `docker/rembg/Dockerfile` (the official `danielgatis/rembg`
  image only publishes `linux/amd64`, so ARM64 hosts need this custom build).
- `docker-compose.prod.yml` — production/VPS: pulls prebuilt images only, no build
  step. Publish your own images first:
  ```bash
  docker build -t ghcr.io/<you>/stirling-pdf-rembg:latest -f docker/embedded/Dockerfile .
  docker push ghcr.io/<you>/stirling-pdf-rembg:latest

  docker build -t ghcr.io/<you>/rembg-arm64:latest -f docker/rembg/Dockerfile docker/rembg
  docker push ghcr.io/<you>/rembg-arm64:latest
  ```
  then update the `image:` fields in `docker-compose.prod.yml` accordingly and run
  `docker compose -f docker-compose.prod.yml up -d`.
- Only `stirling-pdf` needs a public domain — `rembg` is only reachable internally
  on the compose network (`http://rembg:7000`) and should never be exposed publicly.

## Key Capabilities

- **Everywhere you work** - Desktop client, browser UI, and self-hosted server with a private API.
- **50+ PDF tools** - Edit, merge, split, sign, redact, convert, OCR, compress, and more.
- **Automation & workflows** - No-code pipelines direct in UI with APIs to process millions of PDFs.
- **Enterprise‑grade** - SSO, auditing, and flexible on‑prem deployments.
- **Developer platform** - REST APIs available for nearly all tools to integrate into your existing systems.
- **Global UI** - Interface available in 40+ languages.

For a full feature list, see the docs: **https://docs.stirlingpdf.com**

## Quick Start

```bash
docker run -p 8080:8080 docker.stirlingpdf.com/stirlingtools/stirling-pdf
```

Then open: http://localhost:8080

For full installation options (including desktop and Kubernetes), see our [Documentation Guide](https://docs.stirlingpdf.com/#documentation-guide).

## Resources

- [**Documentation**](https://docs.stirlingpdf.com)
- [**Homepage**](https://stirling.com)
- [**API Docs**](https://registry.scalar.com/@stirlingpdf/apis/stirling-pdf-processing-api/)
- [**Server Plan & Enterprise**](https://docs.stirlingpdf.com/Paid-Offerings)

## Support

- **Community** [Discord](https://discord.gg/HYmhKj45pU)
- **Bug Reports**: [Github issues](https://github.com/Stirling-Tools/Stirling-PDF/issues)

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

This project uses [Task](https://taskfile.dev/) as a unified command runner for all build, dev, and test commands. Run `task dev` to get started running the editor, run `task` to see the most common commands, or see the [Developer Guide](DeveloperGuide.md) for full details.

For adding translations, see the [Translation Guide](devGuide/HowToAddNewLanguage.md).

## License

Stirling PDF is open-core. See [LICENSE](LICENSE) for details.
