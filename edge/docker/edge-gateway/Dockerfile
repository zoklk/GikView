# syntax=docker/dockerfile:1
#
# Multi-stage build:
#   1) signing-helper — fetches upstream prebuilt `aws_signing_helper` for the
#      target arch (linux/arm64 required for RPi4). Upstream requires CGO for
#      pkcs11, so building from source under CGO_ENABLED=0 fails; use the
#      official release artifact instead.
#   2) build           — cross-compiles the edge-gateway Go binary.
#   3) runtime         — alpine 3.20 with busybox (wget for smoke probes) +
#      ca-certificates (AWS STS/DynamoDB TLS trust). Pod runs as uid 10001.

ARG GO_VERSION=1.22
ARG ALPINE_VERSION=3.20
ARG SIGNING_HELPER_VERSION=1.5.0

# ── 1. signing helper ────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS signing-helper
ARG TARGETARCH
ARG SIGNING_HELPER_VERSION
# hadolint ignore=DL3018
RUN apk add --no-cache curl ca-certificates \
 && case "${TARGETARCH}" in \
        amd64) arch=X86_64 ;; \
        arm64) arch=Aarch64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && mkdir -p /out \
 && curl -fsSL -o /out/aws_signing_helper \
        "https://rolesanywhere.amazonaws.com/releases/${SIGNING_HELPER_VERSION}/${arch}/Linux/aws_signing_helper" \
 && chmod +x /out/aws_signing_helper

# ── 2. edge-gateway ─────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod ./
RUN go mod download || true
COPY *.go ./
RUN go mod tidy \
 && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
        go build -trimpath -ldflags="-s -w" -o /out/edge-gateway .

# ── 3. runtime ──────────────────────────────────────────────────────────────
FROM alpine:${ALPINE_VERSION}
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates gcompat \
 && addgroup -S -g 10001 edge \
 && adduser  -S -D -u 10001 -G edge edge

COPY --from=signing-helper /out/aws_signing_helper /usr/local/bin/aws_signing_helper
COPY --from=build          /out/edge-gateway       /usr/local/bin/edge-gateway

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/edge-gateway"]
