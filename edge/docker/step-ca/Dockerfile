# syntax=docker/dockerfile:1
#
# Strips cap_net_bind_service from /usr/local/bin/step-ca. With the xattr present
# the kernel refuses to execve the binary under no_new_privs=1
# (allowPrivilegeEscalation: false), exiting 255 before step-ca runs.
# The same image also serves the merge-ca-config initContainer (it ships sh/jq).
FROM cr.smallstep.com/smallstep/step-ca:0.30.2

USER root
# hadolint ignore=DL3018
RUN apk add --no-cache libcap \
 && setcap -r /usr/local/bin/step-ca \
 && apk del libcap

USER step
