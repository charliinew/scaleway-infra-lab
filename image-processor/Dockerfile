# Copyright (c) 2025, Scaleway

# Here, we use the public Rust image as a base image as we step in the shoes
# of a customer. However, Scaleway internal images _must_ be built using the
# Scaleway internal registry. See the handbook for more information:
# https://handbook.internal.scaleway.com/build/guidelines/containers
FROM rust:1.90 AS build

COPY . /usr/src

WORKDIR /usr/src

RUN cargo install --path .

FROM debian:13.1-slim
ENV PORT=9090

RUN apt-get update --quiet --yes && \
  apt-get upgrade --quiet --yes && \
  apt-get install --no-install-recommends --quiet --yes \
  ca-certificates

COPY --from=build --chmod=0755 /usr/src/target/release/image_processor /app/image_processor

WORKDIR /app

EXPOSE ${PORT}

RUN groupadd -f -g 11111 appuser && \
  useradd -l -u 11111 -g appuser -r appuser

USER appuser

ENTRYPOINT [ "/app/image_processor" ]
