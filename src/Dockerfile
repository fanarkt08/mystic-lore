# Image de production d'un service MysticLore, en plusieurs étapes ; SERVICE choisit le service (contexte : src/).
#   docker build -f src/Dockerfile --build-arg SERVICE=accounts -t mysticlore/accounts src
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261104-slim
ARG RUNNER_IMAGE=debian:trixie-20261104-slim

FROM ${ELIXIR_IMAGE} AS build
ARG SERVICE
ENV MIX_ENV=prod
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY shared /app/shared
COPY ${SERVICE}/mix.exs ${SERVICE}/mix.lock /app/${SERVICE}/
WORKDIR /app/${SERVICE}
COPY ${SERVICE}/config/config.exs ${SERVICE}/config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile
# Sources du service (.dockerignore exclut _build, deps, test)
COPY ${SERVICE}/ ./
# Phoenix 1.8 : compiler avant assets.deploy (hooks colocalisés) ; les assets ne concernent que web
RUN mix compile && if [ -d assets ]; then mix assets.deploy; fi
RUN mix release --overwrite && cp -r _build/prod/rel/${SERVICE} /release

FROM ${RUNNER_IMAGE}
ARG SERVICE
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_SERVER=true APP=${SERVICE}
WORKDIR /app
RUN useradd --create-home app
# dossiers des volumes de données : un volume nommé vide hérite de leur propriétaire
RUN mkdir -p /data/accounts /data/social /data/studio && chown app:app /data/accounts /data/social /data/studio
COPY --from=build --chown=app:app /release ./
COPY --chown=app:app docker-entrypoint.sh /app/docker-entrypoint.sh
USER app
ENTRYPOINT ["/app/docker-entrypoint.sh"]
