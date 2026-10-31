# OpenJDK Verified Build -- Diverse Multi-Compilation
#
# Builds OpenJDK from upstream sources inside Astra Linux,
# using N independent boot JDKs to verify absence of backdoors.
#
# Common parameters are in versions.env, per-version ones in versions/
#
# Usage:
#   docker build --build-arg JDK_MAJOR=25 -t jdk-verified:25 .
#   docker run --rm -v $(pwd)/results:/results jdk-verified:25

FROM registry.astralinux.ru/library/astra/ubi18@sha256:b62fb94cf64384778d8c0c0da04a06a30f4ad0abbe18de969caf102e34faf065

ARG JDK_MAJOR=25
ENV JDK_MAJOR=$JDK_MAJOR

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# 1. Build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    bash \
    ca-certificates \
    cpio \
    curl \
    dpkg-dev \
    file \
    g++ \
    gcc \
    git \
    libx11-dev \
    libxext-dev \
    libxrender-dev \
    libxrandr-dev \
    libxtst-dev \
    libxt-dev \
    libcups2-dev \
    libfontconfig1-dev \
    libasound2-dev \
    libelf-dev \
    libpcsclite-dev \
    make \
    pkg-config \
    unzip \
    zip \
    && rm -rf /var/lib/apt/lists/*

# 2. Configuration
COPY versions.env /opt/versions.env
COPY versions/ /opt/versions/

# 3. SDKMAN + boot JDK vendors
ENV SDKMAN_DIR=/opt/sdkman
SHELL ["/bin/bash", "-c"]
RUN curl -s "https://get.sdkman.io" | bash

RUN source "$SDKMAN_DIR/bin/sdkman-init.sh" && \
    source /opt/versions.env && \
    for v in "${VENDORS[@]}"; do sdk install java "$v"; done

# 4. OpenJDK sources
WORKDIR /src
RUN source /opt/versions.env && \
    curl -L -o jdk.tar.gz "$JDK_TARBALL_URL" && \
    tar xf jdk.tar.gz && \
    mv jdk*/ jdk && \
    rm jdk.tar.gz

# 5. Build script
COPY build.sh /opt/build.sh
RUN chmod +x /opt/build.sh

WORKDIR /src/jdk
ENTRYPOINT ["/opt/build.sh"]
