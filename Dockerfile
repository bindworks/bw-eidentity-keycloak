FROM bitnami/keycloak:25.0.2-debian-12-r2

USER root

ENV KEYCLOAK_DOCKER_REVISION=25.0.2-0

RUN apt-get update && apt-get install -y \
  unzip \
  && rm -rf /var/lib/apt/lists/*

COPY ./ /tmp/source/

RUN cd /tmp/source && \
    ls -la && \
    ./build-keycloak-root && \
    cp -R keycloak-root/* /opt/bitnami/keycloak && \
    cd - && \
    rm -rf /tmp/source

USER keycloak

