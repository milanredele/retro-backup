FROM alpine:3.21
RUN apk add --no-cache ntfs-3g ntfs-3g-progs e2fsprogs dosfstools mtools util-linux sfdisk coreutils findutils fuse-exfat exfatprogs
COPY make-victim-inner.sh /usr/local/bin/make-victim-inner.sh
RUN chmod +x /usr/local/bin/make-victim-inner.sh
ENTRYPOINT ["/usr/local/bin/make-victim-inner.sh"]
