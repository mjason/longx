#!/bin/sh
# Longx — install or upgrade, in your own home, no root.
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh -s -- 0.2.0
#   sh install.sh --rollback        # put the previous version back
#
# Puts the program in $LONGX_HOME/app (default ~/.longx), the data in
# $LONGX_HOME/data, and runs it as a systemd --user service on $LONGX_PORT
# (default 7788). Run again to upgrade: the data directory is backed up to
# $LONGX_HOME/backups first, the old program kept as app.old.
#
#   LONGX_HOME=~/.longx   LONGX_PORT=7788   LONGX_NO_SERVICE=1 (just install, don't run)
#   LONGX_TARBALL=/path/to/longx-x.y.z-linux-<arch>.tar.gz (install a local build)
set -eu

REPO="mjason/longx"
HOME_DIR="${LONGX_HOME:-$HOME/.longx}"
PORT="${LONGX_PORT:-7788}"
APP="$HOME_DIR/app"
DATA="$HOME_DIR/data"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/longx.service"

say() { printf '%s\n' "$*"; }
die() { printf 'longx: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "需要 $1，请先安装"; }

# bin/longx honours RELEASE_* from the environment (another release's shell
# exports them — RELEASE_VSN would point it at a version that is not there)
longx_bin() { env -i HOME="$HOME" PATH="$PATH" "$APP/bin/longx" "$@"; }

have_systemd() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

service_active() {
  have_systemd && systemctl --user is-active --quiet longx
}

stop_service() {
  if service_active; then
    say "停止服务…"
    systemctl --user stop longx
  fi
}

arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo x86_64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "不支持的架构 $(uname -m)（有 x86_64 和 arm64 的包）" ;;
  esac
}

latest_version() {
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1
}

rollback() {
  [ -d "$APP.old" ] || die "没有可回退的版本（$APP.old 不存在）"
  stop_service
  rm -rf "$APP.failed"
  [ -d "$APP" ] && mv "$APP" "$APP.failed"
  mv "$APP.old" "$APP"
  say "已换回上一个版本：$(longx_bin version 2>/dev/null || echo '?')"
  if have_systemd && [ -f "$UNIT" ]; then
    systemctl --user start longx
    say "服务已启动。如果新版本跑过数据库迁移，旧版本可能认不得——用 $HOME_DIR/backups 里的备份恢复 data。"
  fi
  exit 0
}

case "${1:-}" in
  --rollback) rollback ;;
  -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
esac

[ "$(uname -s)" = Linux ] || die "只支持 Linux"
need curl; need tar; need sha256sum

mkdir -p "$HOME_DIR" "$DATA" "$HOME_DIR/downloads" "$HOME_DIR/backups"

# ---- the tarball -----------------------------------------------------------
if [ -n "${LONGX_TARBALL:-}" ]; then
  TARBALL="$LONGX_TARBALL"
  VERSION="$(basename "$TARBALL" | sed -n 's/^longx-\([^-]*\)-linux-.*/\1/p')"
  [ -f "$TARBALL" ] || die "找不到 $TARBALL"
else
  VERSION="${1:-${LONGX_VERSION:-}}"
  if [ -z "$VERSION" ]; then
    VERSION="$(latest_version)"
    [ -n "$VERSION" ] || die "查不到最新版本（GitHub API 没有回应）；可以指定版本：install.sh 0.1.0"
  fi
  VERSION="${VERSION#v}"
  NAME="longx-$VERSION-linux-$(arch).tar.gz"
  URL="https://github.com/$REPO/releases/download/v$VERSION/$NAME"
  TARBALL="$HOME_DIR/downloads/$NAME"
  say "下载 $URL …"
  curl -fL --progress-bar -o "$TARBALL" "$URL" || die "下载失败：$URL"
  curl -fsSL -o "$TARBALL.sha256" "$URL.sha256" || die "下载校验文件失败"
  (cd "$HOME_DIR/downloads" && sha256sum -c --quiet "$NAME.sha256") || die "sha256 校验失败，包不完整或被改过"
fi

# ---- the current version, if any ---------------------------------------------
if [ -d "$APP" ]; then
  CURRENT="$(longx_bin version 2>/dev/null | awk '{print $2}')"
  say "当前版本 ${CURRENT:-?} → $VERSION"
  stop_service
  BACKUP="$HOME_DIR/backups/data-$(date +%Y%m%d-%H%M%S).tar.gz"
  say "备份数据目录到 $BACKUP …"
  tar -C "$HOME_DIR" -czf "$BACKUP" data
fi

# ---- unpack, swap ---------------------------------------------------------------
rm -rf "$APP.new"
mkdir -p "$APP.new"
tar -C "$APP.new" --strip-components=1 -xzf "$TARBALL"
[ -x "$APP.new/bin/longx" ] || die "包里没有 bin/longx"
if [ -d "$APP" ]; then
  rm -rf "$APP.old"
  mv "$APP" "$APP.old"
fi
mv "$APP.new" "$APP"
say "已安装 $(longx_bin version) 到 $APP"

# ---- the service ----------------------------------------------------------------
if [ -n "${LONGX_NO_SERVICE:-}" ]; then
  say "启动：LONGX_DATA_DIR=$DATA PORT=$PORT $APP/bin/longx start"
  exit 0
fi

if ! have_systemd; then
  say "没有 systemd --user（容器或非 systemd 的系统）。手动启动："
  say "  LONGX_DATA_DIR=$DATA PORT=$PORT $APP/bin/longx start"
  exit 0
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<UNIT
[Unit]
Description=Longx
After=network.target

[Service]
Environment=LONGX_DATA_DIR=$DATA
Environment=PORT=$PORT
ExecStart=$APP/bin/longx start
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --quiet longx
systemctl --user restart longx

# up? the endpoint answers within a few seconds of the VM starting
i=0
until curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { say "服务没有在 60 秒内响应，看日志：journalctl --user -u longx -n 100"; exit 1; }
  sleep 1
done

if command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
  say "提示：不登录也要常驻的话运行 loginctl enable-linger $USER"
fi

say ""
say "Longx 在跑：http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 127.0.0.1):$PORT"
say "第一次打开「设置 → 模型与 Provider」接入一个模型（DeepSeek / GLM / OpenAI 有预设）。"
say "日志：journalctl --user -u longx -f    回退：sh install.sh --rollback"
