# The gateway: built with the Swift toolchain it needs, then run on the
# smallest base the binary allows. --static-swift-stdlib keeps the Swift
# runtime inside the executable; what remains is glibc 2.43 and libstdc++,
# which is what the Swift image's own Ubuntu ships.

FROM swift:6.4 AS build
WORKDIR /src
COPY . .
RUN swift build -c release --product unladen --static-swift-stdlib \
 && strip .build/release/unladen

FROM ubuntu:26.04
ARG VERSION=dev
ARG REVISION=
ARG STAMP=
LABEL org.opencontainers.image.title="unladen" \
      org.opencontainers.image.description="A lightweight LLM protocol-translating gateway" \
      org.opencontainers.image.source="https://github.com/aisk/unladen" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.created=$STAMP

# Upstreams are reached over HTTPS and the usage log is bucketed by local
# month, so the image carries a trust store and zoneinfo.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/.build/release/unladen /usr/local/bin/unladen

# Configuration, sign-ins (logins.json) and the usage log all resolve here:
# $XDG_CONFIG_HOME/unladen/config.jsonc and $XDG_STATE_HOME/unladen. Both are
# optional; without the file the gateway takes its accounts and models from
# the environment and the flags.
RUN mkdir -p /data/unladen && chown 65532:65532 /data /data/unladen
USER 65532:65532
ENV HOME=/data \
    XDG_CONFIG_HOME=/data \
    XDG_STATE_HOME=/data

EXPOSE 4141
ENTRYPOINT ["/usr/local/bin/unladen"]
CMD ["--host", "0.0.0.0", "--port", "4141"]
