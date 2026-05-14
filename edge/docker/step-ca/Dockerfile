# syntax=docker/dockerfile:1
#
# This image is the step-ca server image with one change: the `cap_net_bind_service` file capability
# is stripped from /usr/local/bin/step-ca. It serves BOTH roles in the step-ca chart:
#
#   1. the MAIN `step-certificates` container. The upstream cr.smallstep.com/smallstep/step-ca image
#      ships the binary with `setcap cap_net_bind_service=+eip` so step-ca can bind ports < 1024 — but
#      this deployment listens on :9000, so it never needs that capability. Worse, a file-capability
#      binary cannot be execve()'d by a process started with no_new_privs=1, which is exactly what the
#      Pod's hardened `containerSecurityContext.allowPrivilegeEscalation: false` (required by trivy
#      KSV-0001) sets — the kernel rejects the exec with EPERM and the container dies immediately with
#      `exec /usr/local/bin/step-ca: operation not permitted` (exit 255), before any step-ca code
#      runs. Removing the xattr lets the hardened securityContext (allowPrivilegeEscalation: false +
#      drop ALL caps) coexist with the binary. (kubernetes/kubernetes#111196, kubernetes/ingress-nginx#10002.)
#
#   2. the `merge-ca-config` initContainer. The upstream step-ca image is Alpine-based and already
#      ships /bin/sh + busybox coreutils (cp, mv, test) + jq — everything the chart's ca.json
#      copy/merge script needs — so the same image covers the init container too (one fewer distinct
#      image to pull; the chart just overrides its command).
#
# Built/pushed multi-arch by the harness as <conventions.registry>/step-ca:<conventions.image_tag>
# (= ghcr.io/zoklk/step-ca:edge). The step-ca VERSION is pinned by the FROM tag below (== chart
# 1.30.1 appVersion). Alpine/apk are arch-agnostic; no TARGETARCH branching needed.
FROM cr.smallstep.com/smallstep/step-ca:0.30.2

# libcap provides setcap; install it as root, clear the binary's file caps (`setcap -r`), then remove
# libcap again so the running image carries no extra tooling.
USER root
# alpine bumps libcap's patch revision frequently; --no-cache + the pinned step-ca (=> pinned alpine)
# base is sufficient version control for this build-only tool. (DL3018 wants libcap=<exact-version>.)
# hadolint ignore=DL3018
RUN apk add --no-cache libcap \
 && setcap -r /usr/local/bin/step-ca \
 && apk del libcap

# back to the upstream image's non-root user (uid/gid 1000) so the image is sane standalone and
# satisfies hadolint DL3002. The chart's containerSecurityContext pins runAsUser/runAsGroup anyway.
USER step
