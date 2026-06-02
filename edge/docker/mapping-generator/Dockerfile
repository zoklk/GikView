# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/mapping-generator .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/mapping-generator /usr/local/bin/mapping-generator
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/mapping-generator"]
