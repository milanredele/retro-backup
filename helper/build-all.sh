#!/bin/sh
# Cross-compile retro-helper for the five supported targets into
# <repo>/out/helper/. Whatever is in helper/bootfiles/ is embedded; run the
# top-level "make helper" (or copy the boot files yourself) first for a
# PXE-capable binary.
#
# Environment: VERSION overrides the version string (default 0.1 plus the
# git commit when available), GO the go command, OUT the output directory.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-"$here/../out/helper"}
go=${GO:-go}

if [ -z "${VERSION:-}" ]; then
	VERSION=0.1
	if rev=$(git -C "$here" rev-parse --short HEAD 2>/dev/null); then
		VERSION="$VERSION+$rev"
		if [ -n "$(git -C "$here" status --porcelain -- . 2>/dev/null)" ]; then
			VERSION="$VERSION-dirty"
		fi
	fi
fi

if [ ! -f "$here/bootfiles/lpxelinux.0" ]; then
	echo "note: helper/bootfiles/lpxelinux.0 is missing; the binaries will receive backups but answer PXE requests with 404 (run make helper)" >&2
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$here"

for target in windows/amd64 darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
	goos=${target%/*}
	goarch=${target#*/}
	name="retro-helper-$goos-$goarch"
	[ "$goos" = windows ] && name="$name.exe"
	echo "building $name ($VERSION)"
	CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch "$go" build -trimpath \
		-ldflags "-s -w -X main.version=$VERSION" -o "$out/$name" .
done

echo
echo "binaries in $out:"
for f in "$out"/retro-helper-*; do
	size=$(wc -c < "$f" | tr -d ' ')
	printf '  %-36s %10s bytes (%s MiB)\n' "$(basename "$f")" "$size" "$(awk "BEGIN { printf \"%.1f\", $size / 1048576 }")"
done
