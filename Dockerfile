FROM debian:bookworm-slim AS providers

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  unzip \
  && rm -rf /var/lib/apt/lists/*

COPY build-keycloak-root /tmp/source/

RUN cd /tmp/source && ./build-keycloak-root


# Base pinned to upstream's numbered build tag, never the floating 26.8.2 tag.
# 26.8.2-1 and -2 shipped a JDK affected by CVE-2026-114938 (Java4Shell: heap
# out-of-bounds write in the x86-64 AVX-512 Base64 decode stub). 26.8.2-3 moved
# to Red Hat OpenJDK 21.0.13.1, the fixed build
# (quay.io/keycloak/keycloak@sha256:7e66a96e4739239070aeaf72e4c5decf0f7f682cfc725b9f7ea2b336eaba38b3).
# Both FROM lines must stay on the same tag. After any base change, verify:
#   docker run --rm --entrypoint java <image> -version   # must be >= 21.0.13.1
FROM quay.io/keycloak/keycloak:26.8.2-3 AS builder

ENV KC_DB=postgres \
    KC_CACHE=ispn \
    KC_CACHE_STACK=jdbc-ping \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_FEATURES=persistent-user-sessions,organization,authorization

COPY --from=providers /tmp/source/keycloak-root/ /opt/keycloak/
COPY themes/ /opt/keycloak/themes/

RUN /opt/keycloak/bin/kc.sh build


FROM quay.io/keycloak/keycloak:26.8.2-3

ENV KEYCLOAK_DOCKER_REVISION=26.8.2-3-bw1

COPY --from=builder /opt/keycloak/ /opt/keycloak/

CMD ["start", "--optimized"]
