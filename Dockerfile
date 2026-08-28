# Single-origin release (Allfather action contract, guide v1):
# serves HTTP on port 4000, runs migrations on boot, reads DATABASE_URL.
#
# The base tag is pinned for reproducibility. hexpm/elixir tags encode
# elixir + OTP + the Debian snapshot, and old ones are withdrawn — if the pull
# 404s, list the current tags and pick the newest matching your elixir version:
#   curl -s 'https://hub.docker.com/v2/repositories/hexpm/elixir/tags/?page_size=100&ordering=last_updated' | grep -o '"name":"[^"]*bookworm[^"]*slim"'
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.1.1-debian-bookworm-20260803-slim
FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update -y && apt-get install -y build-essential git curl && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
ENV MIX_ENV=prod

# The sandbox runs amd64. Building that image on an Apple Silicon laptop goes
# through emulation, where the BEAM's multi-block carrier allocator crashes;
# single-block keeps it alive. Build stage only, and a no-op on native amd64 CI.
ENV ERL_FLAGS="+JMsingle true"

RUN mix local.hex --force && mix local.rebar --force

# mix.* also picks up mix.lock once it is committed (first bootstrap build
# resolves fresh; the CI-resolved lock is committed right after).
COPY mix.* ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY priv priv
COPY lib lib
COPY assets assets

# compile BEFORE assets.deploy: Phoenix 1.8 writes colocated CSS/JS
# (phoenix-colocated/<app>/) at compile time, and Tailwind cannot resolve those
# @import paths until they exist.
RUN mix compile
RUN mix assets.setup
RUN mix assets.deploy
RUN mix release

FROM debian:bookworm-slim AS app
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PORT=4000 PHX_SERVER=true

WORKDIR /app
COPY --from=build /app/_build/prod/rel/gm_bmd ./

EXPOSE 4000
# The release must run migrations on boot — see the build guide.
CMD ["/app/bin/gm_bmd", "start"]
