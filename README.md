# Alambic

Active learning web UI and REST API for two-stage article distillation:

1. **Extraction** — given raw HTML, return an XPath that points at the article body
2. **Cleaning** — given the extracted text, drop non-article tokens (nav bleed, sponsor notices, footers)

Both stages serve predictions from the active model, queue low-confidence
items for human review, and feed confirmed corrections back into independent
retraining pipelines.

See [`docs/design.md`](docs/design.md) for the full spec (API surface,
database schema, web UI flows).

## Stack

- Elixir 1.19 / OTP 28, Phoenix 1.7 (LiveView)
- PostgreSQL 17
- Bandit HTTP server
- Tailwind + esbuild for assets

## Development

Requires [asdf](https://asdf-vm.com) (or matching Elixir/Erlang) and Postgres
running locally.

```bash
just deps      # mix deps.get
just setup     # create db, migrate, install assets
just server    # mix phx.server
```

Visit <http://localhost:4000>.

Common tasks (`just --list` for the full menu):

```bash
just check      # fmt-check + compile + credo + dialyzer + test
just test
just fmt
just db-reset
```

## Deployment

```bash
cp .env.example .env   # then fill in required values
docker compose up -d --build
```

Required env vars (see `docker-compose.yml`):

- `SECRET_KEY_BASE` — generate with `mix phx.gen.secret`
- `PHX_HOST` — public hostname, e.g. `alambic.example.com`
- `ARCHIVE_BASE_URL` — base URL of the archive API
- `POSTGRES_PASSWORD`
- `REVIEW_CONFIDENCE_THRESHOLD` (default `0.7`)

Put an HTTPS-terminating reverse proxy (Caddy, nginx, Cloudflare Tunnel) in
front of port 4000.

## License

[AGPL-3.0](LICENSE). See [`NOTICE`](NOTICE).
