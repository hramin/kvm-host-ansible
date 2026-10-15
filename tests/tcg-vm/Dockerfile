FROM debian:13
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       mmdebstrap e2fsprogs qemu-system-x86 qemu-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
