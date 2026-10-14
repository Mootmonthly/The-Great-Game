# Arena server image (docs/HOSTING.md).
#   docker build -t great-game-arena .
#   docker run -d -p 7878:7878 -v arena-data:/data great-game-arena
FROM rust:1-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p arena-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /data arena \
    && mkdir /data && chown arena /data
COPY --from=build /src/target/release/arena-server /usr/local/bin/arena-server
USER arena
VOLUME /data
EXPOSE 7878
ENTRYPOINT ["arena-server", "serve", "--data", "/data"]
