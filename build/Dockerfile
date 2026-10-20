# Builder for retro-backup: remaster Tiny Core and assemble the pendrive image.
# Build: make builder   (docker build --platform linux/amd64 -t retro-backup-builder build/)
FROM --platform=linux/amd64 debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates cpio gzip xz-utils squashfs-tools \
        syslinux syslinux-common isolinux syslinux-utils \
        mtools dosfstools exfatprogs util-linux fdisk xorriso kmod file pxelinux console-setup-linux \
        unzip fakeroot binutils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
