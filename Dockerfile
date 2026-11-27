# Claude's Computer as a ready-made image: the whole desktop, already installed. For machines where you can run
# Docker but aren't root (some agent sandboxes), or where you'd rather not install a desktop into the machine itself.
#
#   docker run -d --name ccrd --shm-size=2g -v ccrd-state:/state -v ccrd-home:/home/desk \
#     ghcr.io/claudes-computer/claudes-computer
#   docker logs -f ccrd        # prints the Tailscale sign-in link the first time
#
# Settings are environment variables (all optional):
#   CCRD_NAME       the computer's name on your tailnet becomes ccrd-<name>
#   CCRD_TZ         time zone, e.g. America/Los_Angeles
#   CCRD_KBPS       stream bitrate (default 5000; 3000 on a slow link)
#   CCRD_TS_AUTHKEY a Tailscale auth key, to skip the sign-in link
#   HTTPS_PROXY     if the machine reaches the internet through a proxy. Mount the proxy's certificate at
#                   /usr/local/share/ca-certificates/<name>.crt if it re-signs HTTPS.
#   CCRD_PROXY_IP   pin the proxy's host name to this address (some sandboxes resolve it to a dead one in containers)
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive GOFLAGS=-mod=mod
# What the installer itself needs on a bare image; Go only to build Tailscale with our patches, removed afterwards.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends git curl ca-certificates golang-go patch \
 && rm -rf /var/lib/apt/lists/*
COPY cloud /opt/claudes-computer/cloud
COPY CLAUDE.md LICENSE /opt/claudes-computer/
RUN bash /opt/claudes-computer/cloud/install.sh \
 && test -f /opt/ccrd/tailscaled.patched \
 && apt-get purge -y -qq golang-go 'golang-1.*' && apt-get autoremove -y -qq \
 && rm -rf /var/lib/apt/lists/* /root/go /root/.cache /tmp/* /var/tmp/*
ENV CCRD_STATE_DIR=/state
VOLUME ["/state"]
ENTRYPOINT ["/opt/claudes-computer/cloud/docker-start.sh"]
