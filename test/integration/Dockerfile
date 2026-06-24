# Integration sandbox: a REAL cicd-runner + gitolite control plane in one image, with
# docker (the container/isolation leaf) mocked. Lets a single host produce real
# end-to-end integration results without DinD or a second VPS.
#   build:  docker build -f test/integration/Dockerfile -t cicd-integ .   (context = repo root)
#   run:    docker run --rm cicd-integ        # exit 0 = all scenarios passed
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git gitolite3 sudo ca-certificates curl unzip util-linux bsdextrautils procps openssh-client \
    && rm -rf /var/lib/apt/lists/*
# bsdextrautils provides `column` (split out of util-linux on Debian) — ci-status uses
# `column -t` for its table layout; the VPS (Gentoo) ships it via util-linux.

# source tree first — provision + fetch-tools both live here (whole repo IS the runner)
COPY . /opt/cicd-src

# real tools: yq + duckdb via the SAME pinned + sha256-verified path the runner uses
# (fetch-tools). NO duplicate, unverified curl-of-latest install, and no arch-name drift
# (the old hand-rolled `duckdb_cli-linux-aarch64.zip` 404s — fetch-tools maps arm64 right).
RUN CICD_TOOLS_DIR=/usr/local/bin sh /opt/cicd-src/bin/fetch-tools.sh yq duckdb

# the isolation leaf is a trusted black box -> mock docker (no DinD; the test asserts the
# control plane reaches `docker run`, not that a real container ran).
COPY test/integration/mock-docker /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker

RUN useradd -m -s /bin/bash cicd-runner && useradd -m -s /bin/bash git
COPY test/integration/provision.sh /provision.sh
RUN chmod +x /provision.sh && /provision.sh
COPY test/integration/scenarios.sh /scenarios.sh
RUN chmod +x /scenarios.sh
ENTRYPOINT ["/scenarios.sh"]
