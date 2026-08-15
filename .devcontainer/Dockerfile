# Dual-use build container for the inventory workspace:
#   1. Local development via Dev Containers (devcontainer.json builds this).
#   2. Base image for GitHub Actions container jobs (published to
#      ghcr.io/mykelalvis/inventory-devcontainer by the devcontainer-image
#      workflow; ci.yml runs inside it).
# Keep it boring: Ubuntu LTS + Temurin JDK 21 + Maven + git + docker CLI.
# Docker itself is NOT in here — both uses talk to the host's daemon
# (devcontainer: docker-outside-of-docker feature; Actions: the runner's
# socket mounted into the container).
FROM eclipse-temurin:21-jdk-jammy

# ibparent's enforcer requires >= 3.9.16; keep in step with the dev machines.
ARG MAVEN_VERSION=3.9.16

# fontconfig + DejaVu mirror the server's native runtime image: AWT label
# composition renders text, and golden-file tests must rasterize with the
# same fonts the production container uses (macOS glyphs differ).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates unzip zip file gnupg jq \
      fontconfig fonts-dejavu-core \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# dlcdn is the fast CDN but only keeps current releases; archive.apache.org
# has everything but is throttled to ~KB/s — fallback only.
RUN curl -fsSL -o /tmp/maven.tar.gz "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      || curl -fsSL -o /tmp/maven.tar.gz "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    && tar -xz -C /opt -f /tmp/maven.tar.gz \
    && rm /tmp/maven.tar.gz \
    && ln -s /opt/apache-maven-${MAVEN_VERSION} /opt/maven \
    && ln -s /opt/maven/bin/mvn /usr/local/bin/mvn

# just: the workspace task runner (Justfile at the repo root gates on >= 1.58).
ARG JUST_VERSION=1.58.0
RUN curl --proto '=https' --tlsv1.2 -fsSL https://just.systems/install.sh \
      | bash -s -- --tag ${JUST_VERSION} --to /usr/local/bin

ENV MAVEN_HOME=/opt/maven

# Non-root user for Dev Containers ("remoteUser": "vscode"). GitHub Actions
# container jobs ignore this and run as root, which is what they expect —
# so no USER directive here.
RUN useradd -m -s /bin/bash -u 1000 vscode

# The build demands a JDK-21 Maven toolchain; provide it for both users.
COPY toolchains.xml /root/.m2/toolchains.xml
COPY --chown=vscode:vscode toolchains.xml /home/vscode/.m2/toolchains.xml

CMD ["bash"]
