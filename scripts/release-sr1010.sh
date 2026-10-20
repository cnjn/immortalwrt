#!/bin/sh
# Build a release image of the SR1010 firmware and name it after its revision.
#
#   ./scripts/release-sr1010.sh [make arguments]
#
# The firmware reports the revision of the tree it was built from
# (DISTRIB_REVISION, e.g. r38035-d301503f3e), and the update check on the
# routers compares it with the revision at the end of the image name of the
# latest GitHub release. So the tree must be committed and pushed: getver.sh
# names the last commit the branch shares with its upstream, and the count
# grows with every commit.
#
# Run ./scripts/configure-sr1010-flash.sh once before.
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TOPDIR"

IMAGE=bin/targets/zte/zx279133/immortalwrt-zte-zx279133-zte_zxslc-sr1010-flash-squashfs-sysupgrade.bin
OUTDIR=bin/release

die() {
	echo "$*" >&2
	exit 1
}

grep -q "^CONFIG_SR1010_VENDOR_TEMPLATE=" .config 2>/dev/null ||
	die "not configured: run ./scripts/configure-sr1010-flash.sh first"

# An ImmortalWrt release pins its revision in these files; a merge of a new
# upstream release brings them back.
for f in version version.date; do
	[ ! -e "$f" ] || die "$f pins the revision to $(cat "$f"); remove it (git rm $f)"
done

[ -z "$(git status --porcelain --untracked-files=no)" ] ||
	die "the tree has uncommitted changes; commit them first"

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null) ||
	die "the branch has no upstream to push to"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "@{u}")" ] ||
	die "HEAD is not $UPSTREAM: push first (or git fetch, if it was pushed elsewhere)"

REV=$(./scripts/getver.sh)
case "$REV" in
r[0-9]*-[0-9a-f]*) ;;
*) die "unexpected revision: $REV" ;;
esac

make -j"$(nproc)" "$@"

# The root file system must carry the revision the image is named after.
RELEASE_FILE=$(ls -d build_dir/target-*/root-zte/etc/openwrt_release)
grep -qx "DISTRIB_REVISION=" "$RELEASE_FILE" ||
	die "the image reports $(grep DISTRIB_REVISION "$RELEASE_FILE"), not $REV"

mkdir -p "$OUTDIR"
OUT="$OUTDIR/sr1010-owrt-$REV.bin"
cp "$IMAGE" "$OUT"

cat <<MSG

Release image: $OUT
SHA-256: $(sha256sum "$OUT" | cut -d" " -f1)

Publish it as a GitHub release of $UPSTREAM, for example:
  gh release create <tag> $OUT --target $(git rev-parse HEAD) --title <title> --notes-file <notes>
The tag and the title are free text; routers compare the revision in the file name.
MSG
