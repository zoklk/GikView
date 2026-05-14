# syntax=docker/dockerfile:1
# Built multi-arch by the harness: `docker buildx build --platform <build_platforms> --push`.
# The build stage runs natively on $BUILDPLATFORM and cross-compiles via $TARGETOS/$TARGETARCH,
# so no arch-specific binary downloads are needed.
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
# go.mod has no requires (stdlib only) → no go.sum, no module downloads.
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/mapping-generator .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/mapping-generator /usr/local/bin/mapping-generator
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/mapping-generator"]
