# syntax=docker/dockerfile:1.7
FROM elixir:1.19-otp-28-slim AS build

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y git make gcc libc6-dev

WORKDIR /app

ENV MIX_ENV=prod \
    MIX_HOME=/root/.mix \
    HEX_HOME=/root/.hex \
    MIX_OS_DEPS_COMPILE_PARTITION_COUNT=24

RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix deps.get --only prod
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix deps.compile

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY priv priv
COPY lib lib
COPY assets assets

RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix assets.deploy
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix compile
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix release

# --- Runtime ---
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses6 locales curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Install uv (single static binary)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

WORKDIR /app

COPY --from=build /app/_build/prod/rel/alambic ./
COPY scripts ./scripts

COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV PORT=4000 \
    UV_CACHE_DIR=/root/.cache/uv
EXPOSE 4000

ENTRYPOINT ["./entrypoint.sh"]
