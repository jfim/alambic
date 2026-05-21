default:
    @just --list

# Install dependencies
deps:
    mix deps.get

# Create the database, run migrations, install assets
setup:
    mix setup

# Run the Phoenix dev server
server:
    mix phx.server

# Open IEx with the app running
iex:
    iex -S mix phx.server

# Compile with warnings as errors
compile:
    mix compile --warnings-as-errors

# Format code
fmt:
    mix format

# Check formatting
fmt-check:
    mix format --check-formatted

# Run credo (linter)
credo:
    mix credo --strict

# Run dialyzer (static analysis)
dialyzer:
    mix dialyzer

# Run tests
test:
    mix test

# Reset the database (drop + create + migrate + seed)
db-reset:
    mix ecto.reset

# Run all checks (CI equivalent)
check: fmt-check compile credo dialyzer test

# Build a production release locally
release:
    MIX_ENV=prod mix release

# Build the Docker image
docker-build:
    docker build -t alambic:latest .

# Seed dummy models so /api/extract and /api/clean aren't 503 on a fresh DB
db-seed:
    mix run priv/repo/seeds.exs
