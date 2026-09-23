FROM debian:bookworm-slim AS providers

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  unzip \
  && rm -rf /var/lib/apt/lists/*

COPY build-keycloak-root /tmp/source/

RUN cd /tmp/source && ./build-keycloak-root


FROM quay.io/keycloak/keycloak:26.3.3 AS builder

ENV KC_DB=postgres \
    KC_CACHE=ispn \
    KC_CACHE_STACK=jdbc-ping \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_FEATURES=persistent-user-sessions,token-exchange,organization,authorization

COPY --from=providers /tmp/source/keycloak-root/ /opt/keycloak/
COPY themes/ /opt/keycloak/themes/

RUN /opt/keycloak/bin/kc.sh build


FROM quay.io/keycloak/keycloak:26.3.3

ENV KEYCLOAK_DOCKER_REVISION=26.3.3-5

COPY --from=builder /opt/keycloak/ /opt/keycloak/

CMD ["start", "--optimized"]
