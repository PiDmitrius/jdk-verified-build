# OpenJDK Verified Build -- builder image: Astra Linux and the build toolchain.
#
# deps.sh builds this image once and keeps it as an archive; run.sh only loads it.
# Package versions are pinned in versions/<major>.packages; sources and boot JDKs
# are inputs of run.sh, see versions/<major>.lock.

FROM registry.astralinux.ru/library/astra/ubi18@sha256:786169c9a41bfd3de0f5096f7c9e392abc0514284f780f15f6d2192658fa917a

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

ARG JDK_MAJOR=25
COPY versions/${JDK_MAJOR}.packages /tmp/packages
RUN apt-get update \
    && xargs apt-get install -y --no-install-recommends --allow-downgrades < /tmp/packages \
    && rm -rf /var/lib/apt/lists/* /tmp/packages \
    && mkdir -p /inputs /results

CMD ["bash", "/opt/build.sh"]
