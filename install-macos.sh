#!/bin/sh
# One-line macOS entry point; the released Python installer owns all installation.
# curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install-macos.sh | sh
# Add: sh -s -- 0.2.106 (specific release), or --no-service.
set -eu

die() { printf 'longx: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
  -h | --help)
    printf '%s\n' \
      'Usage: sh install-macos.sh [VERSION] [--no-service] [--tarball PATH]' \
      'Requires macOS 14+, native Apple Silicon, Python 3.9+, and curl. Do not use sudo.' \
      'Downloads the latest released installer; passes all arguments to it.' \
      'Options: LONGX_HOME (under your home), LONGX_PORT.'
    exit 0
    ;;
esac

[ "$(uname -s)" = Darwin ] || die "只支持 macOS；Linux 请使用 install.sh"
[ "$(uname -m)" = arm64 ] || die "需要 Apple Silicon，请不要使用 Rosetta 终端"
[ "$(id -u)" != 0 ] || die "请以自己的用户运行，不要使用 sudo/root"
command -v python3 >/dev/null 2>&1 || die "需要 Python 3.9+（仅安装时使用），请先安装"
command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "需要 Python 3.9 或更新版本"

umask 077
installer_dir="$(mktemp -d "${TMPDIR:-/tmp}/longx-installer.XXXXXXXX")"
cleanup() {
  rm -f "$installer_dir/install-macos.py"
  rmdir "$installer_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Download completely before execution: a failed/truncated transfer is never run.
# HTTPS is mandatory for the initial request and every redirect.
curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 15 --max-time 120 --retry 2 \
  --output "$installer_dir/install-macos.py" \
  https://github.com/mjason/longx/releases/latest/download/install-macos.py \
  || die "下载安装器失败，尚未执行安装"
python3 "$installer_dir/install-macos.py" "$@"
