#!/usr/bin/env bash
set -Eeuo pipefail

# TT-linux: unattended Xfce + Xorg dummy display + Chrome + RustDesk.
# Supported target: Ubuntu 22.04/24.04 amd64.

readonly DESKTOP_USER="${TT_DESKTOP_USER:-ttlinux}"
readonly RUSTDESK_PORT="21118"

log() { printf '\n\033[1;32m[TT-linux]\033[0m %s\n' "$*"; }
die() { printf '\n[TT-linux] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "请使用 root 用户运行此脚本。"
fi

if [[ ! -r /etc/os-release ]]; then
  die "无法识别当前 Linux 发行版。"
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != ubuntu && "${ID_LIKE:-}" != *debian* ]]; then
  die "当前仅支持 Ubuntu/Debian 系发行版。"
fi
if [[ $(dpkg --print-architecture) != amd64 ]]; then
  die "Google Chrome 官方 Linux 包仅支持 amd64；当前架构为 $(dpkg --print-architecture)。"
fi

if [[ -z ${RUSTDESK_PASSWORD:-} ]]; then
  if [[ ! -t 0 ]]; then
    die "非交互运行时请通过 RUSTDESK_PASSWORD 环境变量提供永久密码。"
  fi
  while :; do
    read -r -s -p "请输入 RustDesk 永久密码（至少 6 位）: " RUSTDESK_PASSWORD
    printf '\n'
    [[ ${#RUSTDESK_PASSWORD} -ge 6 ]] || { echo "密码至少需要 6 位。"; continue; }
    read -r -s -p "请再次输入 RustDesk 永久密码: " password_confirm
    printf '\n'
    [[ "$RUSTDESK_PASSWORD" == "$password_confirm" ]] && break
    echo "两次输入不一致，请重试。"
  done
fi
[[ ${#RUSTDESK_PASSWORD} -ge 6 ]] || die "RustDesk 永久密码至少需要 6 位。"

if [[ -z ${TT_SCREEN_MODE:-} ]]; then
  if [[ -t 0 ]]; then
    printf '\n请选择桌面分辨率：\n'
    printf '  1) 1600x900\n'
    printf '  2) 1920x1080（默认）\n'
    printf '  3) 2560x1440\n'
    read -r -p '请输入选项 [2]: ' screen_choice
    case "${screen_choice:-2}" in
      1) SCREEN_MODE="1600x900" ;;
      2) SCREEN_MODE="1920x1080" ;;
      3) SCREEN_MODE="2560x1440" ;;
      *) die "无效的分辨率选项：${screen_choice}" ;;
    esac
  else
    SCREEN_MODE="1920x1080"
  fi
else
  SCREEN_MODE="$TT_SCREEN_MODE"
fi

case "$SCREEN_MODE" in
  1600x900)
    SCREEN_WIDTH=1600; SCREEN_HEIGHT=900
    SCREEN_MODELINE='108.00 1600 1624 1704 1800 900 901 904 1000 +HSync +VSync'
    ;;
  1920x1080)
    SCREEN_WIDTH=1920; SCREEN_HEIGHT=1080
    SCREEN_MODELINE='148.50 1920 2008 2052 2200 1080 1084 1089 1125 +HSync +VSync'
    ;;
  2560x1440)
    SCREEN_WIDTH=2560; SCREEN_HEIGHT=1440
    SCREEN_MODELINE='241.50 2560 2608 2640 2720 1440 1443 1448 1481 +HSync -VSync'
    ;;
  *) die "不支持的分辨率：${SCREEN_MODE}；可选值为 1600x900、1920x1080、2560x1440。" ;;
esac

export DEBIAN_FRONTEND=noninteractive
log "安装 Xfce、Xorg Dummy 驱动、中文字体及运行依赖"
apt-get update
apt-get install -y --no-install-recommends \
  xfce4 xfce4-terminal xfce4-power-manager lightdm dbus-x11 \
  xserver-xorg-core xserver-xorg-video-dummy x11-xserver-utils xdotool \
  curl ca-certificates gnupg python3 locales language-pack-zh-hans \
  fonts-noto-cjk fonts-wqy-microhei fonts-wqy-zenhei fontconfig \
  libayatana-appindicator3-1 libxdo3

log "安装 Google Chrome Stable"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
chmod 0644 /etc/apt/keyrings/google-chrome.gpg
cat >/etc/apt/sources.list.d/google-chrome.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main
EOF
apt-get update
apt-get install -y google-chrome-stable

log "安装最新版 RustDesk"
rustdesk_url="$(python3 - <<'PY'
import json, urllib.request
req = urllib.request.Request(
    "https://api.github.com/repos/rustdesk/rustdesk/releases/latest",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "TT-linux-installer"},
)
with urllib.request.urlopen(req, timeout=30) as response:
    release = json.load(response)
assets = [a for a in release.get("assets", [])
          if a["name"].endswith("-x86_64.deb") and "sciter" not in a["name"]]
if not assets:
    raise SystemExit("未找到 RustDesk x86_64 deb 安装包")
print(assets[0]["browser_download_url"])
PY
)"
rustdesk_deb="$(mktemp --suffix=.deb)"
trap 'rm -f "$rustdesk_deb"' EXIT
curl -fL --retry 3 -o "$rustdesk_deb" "$rustdesk_url"
apt-get install -y "$rustdesk_deb"

log "创建桌面用户 ${DESKTOP_USER}"
if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DESKTOP_USER"
fi
usermod -aG video,input,render,audio "$DESKTOP_USER"
desktop_home="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" \
  "$desktop_home/Desktop" "$desktop_home/.config/autostart" \
  "$desktop_home/.config/xfce4" "$desktop_home/.local/share/applications"

log "配置固定 ${SCREEN_MODE} Xorg Dummy 显示器"
install -d -m 0755 /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/20-ttlinux-dummy.conf <<EOF
Section "Device"
    Identifier  "TTLinuxDummyDevice"
    Driver      "dummy"
    VideoRam    256000
EndSection

Section "Monitor"
    Identifier  "TTLinuxDummyMonitor"
    HorizSync   28.0-120.0
    VertRefresh 48.0-75.0
    Modeline "${SCREEN_MODE}" ${SCREEN_MODELINE}
    Option      "PreferredMode" "${SCREEN_MODE}"
EndSection

Section "Screen"
    Identifier "TTLinuxDummyScreen"
    Device     "TTLinuxDummyDevice"
    Monitor    "TTLinuxDummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "${SCREEN_MODE}"
        Virtual ${SCREEN_WIDTH} ${SCREEN_HEIGHT}
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "TTLinuxDummyLayout"
    Screen     "TTLinuxDummyScreen"
EndSection
EOF

log "配置 LightDM 自动登录 Xfce/X11"
install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-ttlinux.conf <<EOF
[Seat:*]
autologin-user=${DESKTOP_USER}
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
xserver-command=X -core -noreset
EOF
systemctl enable lightdm.service

log "关闭锁屏、屏保、DPMS 与系统睡眠"
cat >/usr/local/bin/ttlinux-session-setup <<'EOF'
#!/usr/bin/env bash
set -u
export DISPLAY="${DISPLAY:-:0}"
xset s off
xset s noblank
xset -dpms
# RustDesk system service runs as root; grant only that local user X11 access.
xhost +SI:localuser:root >/dev/null
pkill -x light-locker 2>/dev/null || true
pkill -x xfce4-screensaver 2>/dev/null || true

set_xfce() {
  local channel="$1" property="$2" type="$3" value="$4"
  xfconf-query -c "$channel" -p "$property" -s "$value" 2>/dev/null || \
    xfconf-query -c "$channel" -p "$property" -n -t "$type" -s "$value" 2>/dev/null || true
}
set_xfce xfce4-power-manager /xfce4-power-manager/blank-on-ac int 0
set_xfce xfce4-power-manager /xfce4-power-manager/dpms-enabled bool false
set_xfce xfce4-power-manager /xfce4-power-manager/inactivity-on-ac int 0
set_xfce xfce4-power-manager /xfce4-power-manager/lock-screen-suspend-hibernate bool false
set_xfce xfce4-session /shutdown/LockScreen bool false
EOF
chmod 0755 /usr/local/bin/ttlinux-session-setup
cat >"$desktop_home/.config/autostart/ttlinux-session.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=TT-linux 会话设置
Exec=/usr/local/bin/ttlinux-session-setup
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
Terminal=false
EOF
cat >"$desktop_home/.config/autostart/xfce4-screensaver.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable Xfce Screensaver
Hidden=true
EOF
cat >"$desktop_home/.config/autostart/light-locker.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable Light Locker
Hidden=true
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null

log "配置中文 UTF-8 环境及字体缓存"
locale-gen zh_CN.UTF-8
cat >"$desktop_home/.xprofile" <<'EOF'
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh:en_US:en
export XDG_SESSION_TYPE=x11
EOF
cat >"$desktop_home/.config/user-dirs.dirs" <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
EOF
fc-cache -f

log "创建解除跨域限制并提高 nofile 限制的 Chrome 桌面启动脚本"
cat >"$desktop_home/Desktop/start-chrome.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CHROME_NOFILE_LIMIT="${CHROME_NOFILE_LIMIT:-65535}"
case "$CHROME_NOFILE_LIMIT" in
  ''|*[!0-9]*) echo "CHROME_NOFILE_LIMIT 必须为正整数" >&2; exit 1 ;;
esac
hard_limit="$(ulimit -Hn)"
if [[ "$hard_limit" != unlimited && "$CHROME_NOFILE_LIMIT" -gt "$hard_limit" ]]; then
  CHROME_NOFILE_LIMIT="$hard_limit"
fi
ulimit -Sn "$CHROME_NOFILE_LIMIT"

exec /usr/bin/google-chrome-stable \
  --disable-web-security \
  --disable-dev-shm-usage \
  --no-default-browser-check \
  --no-first-run \
  --user-data-dir="$HOME/.config/google-chrome-ttlinux" \
  "$@"
EOF
chmod 0755 "$desktop_home/Desktop/start-chrome.sh"
cat >"$desktop_home/Desktop/Chrome-TT.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Chrome（跨域模式）
Comment=以 nofile 65535 和禁用 Web 安全策略启动 Chrome
Exec=${desktop_home}/Desktop/start-chrome.sh
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
EOF
chmod 0755 "$desktop_home/Desktop/Chrome-TT.desktop"

cat >/etc/security/limits.d/99-ttlinux-nofile.conf <<EOF
${DESKTOP_USER} soft nofile 65535
${DESKTOP_USER} hard nofile 65535
EOF
chown -R "$DESKTOP_USER:$DESKTOP_USER" \
  "$desktop_home/Desktop" "$desktop_home/.config" "$desktop_home/.xprofile"

log "配置 RustDesk 永久密码与 IP 直连（TCP ${RUSTDESK_PORT}）"
systemctl enable --now rustdesk.service
for _ in {1..30}; do
  [[ -S /var/run/rustdesk-ipc || -S /run/rustdesk-ipc ]] && break
  sleep 1
done
rustdesk --password "$RUSTDESK_PASSWORD"
rustdesk --option direct-server Y
systemctl restart rustdesk.service
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow "${RUSTDESK_PORT}/tcp" comment 'RustDesk direct IP' >/dev/null
fi

log "启动图形桌面"
systemctl set-default graphical.target
systemctl restart lightdm.service

rustdesk_id=""
for _ in {1..60}; do
  rustdesk_id="$(rustdesk --get-id 2>/dev/null | tr -d '\r\n[:space:]' || true)"
  [[ -n "$rustdesk_id" && "$rustdesk_id" != 0 ]] && break
  sleep 2
done
[[ -n "$rustdesk_id" ]] || rustdesk_id="（服务仍在注册，请稍后运行 rustdesk --get-id）"
public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$public_ip" ]] || public_ip="$(hostname -I | awk '{print $1}')"

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m TT-linux 安装完成\033[0m\n'
printf ' 桌面用户       : %s\n' "$DESKTOP_USER"
printf ' 桌面分辨率     : %s\n' "$SCREEN_MODE"
printf ' RustDesk 设备 ID: %s\n' "$rustdesk_id"
printf ' IP 直连地址    : %s:%s\n' "$public_ip" "$RUSTDESK_PORT"
printf ' Chrome 启动脚本: %s/Desktop/start-chrome.sh\n' "$desktop_home"
printf '\033[1;32m============================================================\033[0m\n'
