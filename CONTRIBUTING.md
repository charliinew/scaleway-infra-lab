# Contributing

Contributions are welcome. Here's how to get started.

## Prerequisites

- [mise](https://mise.jdx.dev/) to manage tool versions (see `mise.toml`)
- Docker with buildx
- [Terraform](https://developer.hashicorp.com/terraform/downloads)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Scaleway CLI](https://www.scaleway.com/en/docs/develop-and-test/install-tools/) (`scw`)

## Local setup

```bash
cp dot.env .env
# fill in .env with your Scaleway credentials
docker compose up
```

## Running the linter

```bash
pip install ruff
ruff check rest-api/
ruff check image-converter/
ruff check ai-alt-generator/
```

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Ensure the linter passes
4. Open a pull request

## Project structure

```
.
├── rest-api/           # Python/FastAPI service (main API, orchestration)
├── image-converter/    # Python Serverless Container (multi-format conversion)
├── ai-alt-generator/   # Python Serverless Container (Qwen Vision alt-text)
├── k8s/               # Kubernetes manifests (deployment, HPA, monitoring)
├── terraform/          # Infrastructure as code (Scaleway)
├── migrations/         # Database schema migrations
├── scripts/            # Operational scripts (backup, health, rotation)
├── docs/               # Documentation (architecture, runbooks, API)
├── docker-compose.yml  # Local development
└── dot.env             # Environment variables template
```
