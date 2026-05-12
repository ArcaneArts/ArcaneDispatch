# Multi-stage build for the dispatch-speed-server. We bake a tiny final
# image (~12 MB) so a Hetzner/DigitalOcean VPS deploy is just `docker
# compose up -d` after copying the auth.json / server.key into the
# bind-mounted volume.
#
# The runtime image is distroless so the attack surface is minimal — no
# shell, no busybox, no extra binaries. If you need to exec in for
# debugging, change `gcr.io/distroless/static-debian12` to `:debug` and
# rebuild.

# ---- build stage -------------------------------------------------------
FROM golang:1.22-alpine AS build
WORKDIR /src

# Cache the go.mod download layer independently from the source layer so
# rebuilds after a code change don't re-pull every dep.
COPY go.mod ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 makes the binary fully static so distroless/static will
# actually run it. -trimpath drops the build-host paths from stack traces.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/dispatch-speed-server \
    .

# ---- runtime stage -----------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

# UDP/TCP for bonded transport; TCP for /stats HTTP.
EXPOSE 4430/udp
EXPOSE 4430/tcp
EXPOSE 9090/tcp

# Operators MUST bind-mount a /data volume so the auth store and server
# key survive container restarts. We default to /data/* in the entrypoint
# so a single `-v dispatch:/data` is enough.
VOLUME ["/data"]

COPY --from=build /out/dispatch-speed-server /usr/local/bin/dispatch-speed-server

USER nonroot:nonroot

# Default to `serve`; subcommands like `genkey` / `adduser` are reachable
# via `docker run --rm -v dispatch:/data dispatch-speed-server adduser ...`
ENTRYPOINT ["/usr/local/bin/dispatch-speed-server"]
CMD ["serve", \
     "-udp", ":4430", \
     "-tcp", ":4430", \
     "-stats", ":9090", \
     "-auth", "/data/auth.json", \
     "-key", "/data/server.key"]
