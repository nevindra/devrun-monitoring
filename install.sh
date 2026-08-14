#!/bin/sh
#
# devrun installer.
#
#   curl -fsSL https://raw.githubusercontent.com/nevindra/devrun-monitoring/main/install.sh | sh
#
# This is also what `devrun update` runs, which is why there is only one of it:
# the download, the checksum and the swap are the same operation whether or not
# a devrun is already there, and two copies of that logic drift apart.
#
# Environment:
#   DEVRUN_INSTALL_DIR   where to put the binary (default: ~/.local/bin)
#   DEVRUN_VERSION       install this version instead of the latest
#   DEVRUN_FROM          the version being replaced; set by `devrun update`
#   GITHUB_TOKEN         used for the release lookup if the API rate-limits you

set -eu

REPO="nevindra/devrun-monitoring"
managed=0

say() { printf '%s\n' "$*"; }
err() { printf 'devrun: %s\n' "$*" >&2; }

die() {
	err "$@"
	exit 1
}

usage() {
	cat <<'EOF'
Install devrun.

Usage: install.sh [--dir DIR] [--version VERSION]

  --dir DIR          where to put the binary (default: ~/.local/bin)
  --version VERSION  install this version instead of the latest
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--managed) managed=1 ;;
	--dir)
		[ $# -ge 2 ] || die "--dir needs a directory"
		DEVRUN_INSTALL_DIR="$2"
		shift
		;;
	--version)
		[ $# -ge 2 ] || die "--version needs a version"
		DEVRUN_VERSION="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option \"$1\"" ;;
	esac
	shift
done

# ---------------------------------------------------------------- platform

# Linux only, and said out loud rather than discovered three steps later when a
# tarball turns out to hold an ELF binary. devrun talks to /proc and to Linux
# syscalls directly; there is no macOS build to fall back to.
os=$(uname -s)
[ "$os" = "Linux" ] || die "devrun is Linux only (this is $os). See the README for why."

machine=$(uname -m)
case "$machine" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*) die "no prebuilt binary for $machine. Build from source: https://github.com/$REPO" ;;
esac

# ---------------------------------------------------------------- tools

if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL "$1"; }
	fetch_to() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -qO- "$1"; }
	fetch_to() { wget -qO "$2" "$1"; }
else
	die "need curl or wget"
fi

# The checksum is not optional. A tarball that arrived over a hijacked proxy
# and a tarball that arrived intact look identical until something checks, and
# "install it anyway" is not a decision an installer gets to make quietly.
if command -v sha256sum >/dev/null 2>&1; then
	sum() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	die "need sha256sum or shasum to verify the download"
fi

command -v tar >/dev/null 2>&1 || die "need tar"

# ---------------------------------------------------------------- version

if [ -n "${DEVRUN_VERSION:-}" ]; then
	version=${DEVRUN_VERSION#v}
else
	api="https://api.github.com/repos/$REPO/releases/latest"
	if [ -n "${GITHUB_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
		latest=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$api" || true)
	else
		latest=$(fetch "$api" || true)
	fi
	version=$(printf '%s' "$latest" | sed -n 's/.*"tag_name"[ ]*:[ ]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)
	[ -n "$version" ] || die "could not find the latest release. Set DEVRUN_VERSION, or see https://github.com/$REPO/releases"
fi

# `devrun update` passes what it already is. Stopping here keeps an update on a
# current machine from rewriting a perfectly good binary — and, more to the
# point, from doing it silently.
if [ "$managed" = "1" ] && [ "${DEVRUN_FROM:-}" = "$version" ]; then
	say "devrun $version is already the latest release."
	exit 0
fi

# ---------------------------------------------------------------- destination

dir=${DEVRUN_INSTALL_DIR:-"$HOME/.local/bin"}
mkdir -p "$dir" 2>/dev/null || die "cannot create $dir"
[ -w "$dir" ] || die "$dir is not writable. Re-run with sudo, or set DEVRUN_INSTALL_DIR to somewhere you own."

# ---------------------------------------------------------------- fetch

tarball="devrun-$version-$arch-linux.tar.gz"
base="https://github.com/$REPO/releases/download/v$version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "devrun $version ($arch) → $dir"

fetch_to "$base/$tarball" "$tmp/$tarball" ||
	die "could not download $base/$tarball"
fetch_to "$base/SHA256SUMS" "$tmp/SHA256SUMS" ||
	die "could not download the checksums for $version"

want=$(sed -n "s/^\([0-9a-f]\{64\}\)[ *]*$tarball\$/\1/p" "$tmp/SHA256SUMS" | head -n 1)
[ -n "$want" ] || die "SHA256SUMS has no entry for $tarball"

got=$(sum "$tmp/$tarball")
if [ "$got" != "$want" ]; then
	err "checksum mismatch on $tarball"
	err "  expected $want"
	err "  got      $got"
	exit 1
fi

tar -xzf "$tmp/$tarball" -C "$tmp" || die "could not unpack $tarball"
[ -f "$tmp/devrun" ] || die "$tarball did not contain a devrun binary"

# ---------------------------------------------------------------- install

# Staged beside the target and renamed into place, so the swap is one atomic
# operation on the same filesystem: nobody ever sees a half-written devrun, and
# a `mv` over a *running* binary is fine on Linux — the old inode stays alive
# for whoever still has it open.
staged="$dir/.devrun.$$"
cp "$tmp/devrun" "$staged" || die "cannot write to $dir"
chmod 755 "$staged"
mv -f "$staged" "$dir/devrun" || {
	rm -f "$staged"
	die "cannot replace $dir/devrun"
}

if [ -n "${DEVRUN_FROM:-}" ]; then
	say "devrun $DEVRUN_FROM → $version"
else
	say "devrun $version installed to $dir/devrun"
fi

# ---------------------------------------------------------------- path

case ":${PATH:-}:" in
*":$dir:"*) ;;
*)
	say ""
	say "$dir is not on your PATH. Add it:"
	say ""
	say "  export PATH=\"$dir:\$PATH\""
	say ""
	say "…in ~/.profile, ~/.bashrc or ~/.zshrc, whichever your shell reads."
	;;
esac
