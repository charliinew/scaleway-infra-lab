# Contributing

Contributions are welcome. Here's how to get started.

## Prerequisites

- [mise](https://mise.jdx.dev/) to manage tool versions (see `mise.toml`)
- Docker with buildx
- Terraform (for infrastructure changes)

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
```

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Ensure the linter passes
4. Open a pull request

## Project structure

```
.
├── rest-api/           # Python/FastAPI service
├── image-processor/    # Rust/actix-web service
├── terraform/          # Infrastructure as code (Scaleway)
├── challenges/         # Dev journal
├── scripts/            # Utility scripts
├── docker-compose.yml  # Local development
└── dot.env             # Environment variables template
```
