#!/usr/bin/env bash
set -Eeuo pipefail

# TT-linux: unattended Xfce + Xorg dummy display + Chrome + remote control.
# Supported target: Ubuntu 22.04/24.04 amd64.

readonly DESKTOP_USER="${TT_DESKTOP_USER:-ttlinux}"
readonly RUSTDESK_PORT="21118"
readonly SWAP_SIZE_GB="${TT_SWAP_SIZE_GB:-4}"
readonly UU_BRIDGE_COMMIT="75405e83a6ce0ac5b588aeead54cfa234d192edb"
readonly UU_BRIDGE_DIR="/opt/uu-remote-ubuntu-bridge"

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
if [[ ! "$DESKTOP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  die "TT_DESKTOP_USER 必须是有效的 Linux 用户名（小写字母、数字、下划线或连字符）。"
fi
if [[ ! "$SWAP_SIZE_GB" =~ ^[1-9][0-9]*$ ]] || (( 10#$SWAP_SIZE_GB > 64 )); then
  die "TT_SWAP_SIZE_GB 必须是 1 到 64 之间的整数。"
fi

# Prefer the controlling terminal for prompts. Some web SSH consoles do not
# provide /dev/tty but do provide a terminal on stdin, so support that as well.
PROMPT_INPUT=/dev/tty
HAS_TTY=false
if ( : </dev/tty ) 2>/dev/null; then
  HAS_TTY=true
elif [[ -t 0 ]]; then
  PROMPT_INPUT=/dev/stdin
  HAS_TTY=true
fi

REMOTE_SOFTWARE="${TT_REMOTE:-}"
if [[ -z "$REMOTE_SOFTWARE" ]]; then
  if [[ $HAS_TTY == true ]]; then
    printf '\n请选择远程控制软件：\n'
    printf '  1) UU Remote（支持 Ubuntu 22.04 / 24.04）\n'
    printf '  2) RustDesk（默认）\n'
    read -r -p '请输入选项 [2]: ' remote_choice <"$PROMPT_INPUT"
    case "${remote_choice:-2}" in
      1) REMOTE_SOFTWARE="uu-remote" ;;
      2) REMOTE_SOFTWARE="rustdesk" ;;
      *) die "无效的远控软件选项：${remote_choice}" ;;
    esac
  else
    REMOTE_SOFTWARE="rustdesk"
  fi
fi
case "${REMOTE_SOFTWARE,,}" in
  uu|uu-remote|uuremote) REMOTE_SOFTWARE="uu-remote" ;;
  rustdesk) REMOTE_SOFTWARE="rustdesk" ;;
  *) die "TT_REMOTE 仅支持 uu-remote 或 rustdesk。" ;;
esac
if [[ "$REMOTE_SOFTWARE" == "uu-remote" &&
      ( "${ID:-}" != ubuntu ||
        ( "${VERSION_ID:-}" != 22.04 && "${VERSION_ID:-}" != 24.04 ) ) ]]; then
  die "UU Remote Bridge 当前支持 Ubuntu 22.04 / 24.04 amd64；当前系统为 ${PRETTY_NAME:-未知}。"
fi

if [[ "$REMOTE_SOFTWARE" == "rustdesk" && -z ${RUSTDESK_PASSWORD:-} ]]; then
  if [[ $HAS_TTY != true ]]; then
    die "选择 RustDesk 非交互安装时，请通过 RUSTDESK_PASSWORD 环境变量提供永久密码。"
  fi
  while :; do
    read -r -s -p "请输入 RustDesk 永久密码（至少 6 位）: " RUSTDESK_PASSWORD <"$PROMPT_INPUT"
    printf '\n'
    [[ ${#RUSTDESK_PASSWORD} -ge 6 ]] || { echo "密码至少需要 6 位。"; continue; }
    read -r -s -p "请再次输入 RustDesk 永久密码: " password_confirm <"$PROMPT_INPUT"
    printf '\n'
    [[ "$RUSTDESK_PASSWORD" == "$password_confirm" ]] && break
    echo "两次输入不一致，请重试。"
  done
fi
if [[ "$REMOTE_SOFTWARE" == "rustdesk" ]]; then
  [[ ${#RUSTDESK_PASSWORD} -ge 6 ]] || die "RustDesk 永久密码至少需要 6 位。"
fi

if [[ -z ${TT_SCREEN_MODE:-} ]]; then
  if [[ $HAS_TTY == true ]]; then
    printf '\n请选择桌面分辨率：\n'
    printf '  1) 1600x900\n'
    printf '  2) 1920x1080（默认）\n'
    printf '  3) 2560x1440\n'
    read -r -p '请输入选项 [2]: ' screen_choice <"$PROMPT_INPUT"
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

log "配置 ${SWAP_SIZE_GB} GiB Swap（vm.swappiness=10）"
swapfile=/swapfile
expected_swap_bytes=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
current_swap_bytes=0
if [[ -f "$swapfile" ]]; then
  current_swap_bytes="$(stat -c %s "$swapfile" 2>/dev/null || echo 0)"
fi

if [[ "$current_swap_bytes" -ne "$expected_swap_bytes" ]]; then
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$swapfile"; then
    swapoff "$swapfile"
  fi
  rm -f "$swapfile"
  if ! fallocate -l "${SWAP_SIZE_GB}G" "$swapfile"; then
    dd if=/dev/zero of="$swapfile" bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
  fi
  chmod 0600 "$swapfile"
  mkswap "$swapfile" >/dev/null
fi

if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$swapfile"; then
  # Some filesystems reject fallocate-created swap files. Recreate it with dd
  # in that case so the installer also works on such server images.
  if ! swapon "$swapfile" 2>/dev/null; then
    rm -f "$swapfile"
    dd if=/dev/zero of="$swapfile" bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
    chmod 0600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    swapon "$swapfile"
  fi
fi
grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || \
  printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
cat >/etc/sysctl.d/99-ttlinux-swap.conf <<'EOF'
vm.swappiness=10
EOF
sysctl -q -p /etc/sysctl.d/99-ttlinux-swap.conf

log "限制 systemd-journald 日志占用"
install -d -m 0755 /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-ttlinux.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald.service

log "关闭系统 Core Dump，避免 Chrome 崩溃转储占满磁盘"
install -d -m 0755 /etc/systemd/coredump.conf.d
cat >/etc/systemd/coredump.conf.d/99-ttlinux.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

log "关闭 Ubuntu 错误报告服务"
for report_unit in \
  apport.service apport-autoreport.service apport-autoreport.path \
  whoopsie.service; do
  if systemctl list-unit-files "$report_unit" --no-legend 2>/dev/null | grep -q .; then
    systemctl mask --now "$report_unit" >/dev/null 2>&1 || true
  fi
done
if [[ -f /etc/default/apport ]]; then
  if grep -q '^enabled=' /etc/default/apport; then
    sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
  else
    printf '\nenabled=0\n' >>/etc/default/apport
  fi
fi

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

if [[ "$REMOTE_SOFTWARE" == "rustdesk" ]]; then
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
  curl -fL --retry 3 -o "$rustdesk_deb" "$rustdesk_url"
  apt-get install -y "$rustdesk_deb"
  rm -f "$rustdesk_deb"
fi

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
pkill -x xfce4-power-manager 2>/dev/null || true

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
set_xfce xfwm4 /general/use_compositing bool false
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
cat >"$desktop_home/.config/autostart/xfce4-power-manager.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable Xfce Power Manager
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

if [[ "$REMOTE_SOFTWARE" == "rustdesk" ]]; then
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
fi

log "启动图形桌面"
systemctl set-default graphical.target
systemctl restart lightdm.service

if [[ "$REMOTE_SOFTWARE" == "uu-remote" ]]; then
  log "安装 UU Remote Ubuntu Bridge（XFCE/X11 适配）"

  # Upstream deliberately targets Ubuntu 24.04 GNOME. Keep TT-linux's XFCE
  # desktop unchanged and select upstream's loopback-only X11/VNC relay.
  apt-get install -y --no-install-recommends git sudo
  if [[ ! -f "$UU_BRIDGE_DIR/.ttlinux-upstream-commit" ]] ||
     [[ "$(cat "$UU_BRIDGE_DIR/.ttlinux-upstream-commit" 2>/dev/null || true)" != "$UU_BRIDGE_COMMIT" ]]; then
    uu_bridge_stage="$(mktemp -d)"
    curl -fL --retry 3 \
      "https://github.com/lachlanchen/uu-remote-ubuntu-bridge/archive/${UU_BRIDGE_COMMIT}.tar.gz" \
      | tar -xz --strip-components=1 -C "$uu_bridge_stage"
    rm -rf "$UU_BRIDGE_DIR"
    mv "$uu_bridge_stage" "$UU_BRIDGE_DIR"
    printf '%s\n' "$UU_BRIDGE_COMMIT" >"$UU_BRIDGE_DIR/.ttlinux-upstream-commit"
  fi

  # Apply the minimal compatibility layer locally: discover xfce4-session,
  # accept a noninteractive relay secret, and avoid GNOME RDP/keyring changes
  # when the VNC relay is selected.
  python3 - "$UU_BRIDGE_DIR" "${VERSION_ID:-}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
installer = root / "install.sh"
bridge = root / "scripts/uu-remote-bridge"

text = installer.read_text()
ubuntu_version = sys.argv[2]

# TT-linux uses the X11/VNC relay on both supported releases. Upstream only
# blocks Jammy because its validated GNOME/RDP route targets Noble; the VNC
# route does not use that GNOME relay. Keep the host-side diagnostic client at
# the version available from each Ubuntu archive.
old_guard = '''if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
    printf 'Only Ubuntu 24.04 is currently supported; detected %s %s.\\n' \\
        "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
    exit 1
fi'''
new_guard = '''if [[ "${ID:-}" != ubuntu ||
      ( "${VERSION_ID:-}" != 22.04 && "${VERSION_ID:-}" != 24.04 ) ]]; then
    printf 'Only Ubuntu 22.04 and 24.04 are supported; detected %s %s.\\n' \\
        "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
    exit 1
fi'''
if old_guard in text:
    text = text.replace(old_guard, new_guard, 1)
elif "Only Ubuntu 22.04 and 24.04 are supported" not in text:
    raise SystemExit("无法应用 UU Bridge Ubuntu 22.04 系统检查适配")

if ubuntu_version == "22.04":
    text = text.replace("freerdp3-x11", "freerdp2-x11")
elif ubuntu_version == "24.04":
    text = text.replace("freerdp2-x11", "freerdp3-x11")
else:
    raise SystemExit(f"不支持的 Ubuntu 版本：{ubuntu_version or '未知'}")

if "UURB_RELAY_PASSWORD:-" not in text:
    old = '''rdp_password="$("$secret_tool_bin" lookup service uu-desktop-bridge \\
    username "$bridge_user" || true)"'''
    new = '''rdp_password="${UURB_RELAY_PASSWORD:-}"
if [[ -z "$rdp_password" ]]; then
    rdp_password="$("$secret_tool_bin" lookup service uu-desktop-bridge \\
        username "$bridge_user" || true)"
fi'''
    if old not in text:
        raise SystemExit("无法应用 UU Bridge 非交互密码适配")
    text = text.replace(old, new, 1)

grd = '''"$grdctl_bin" rdp set-port "$rdp_port"
"$grdctl_bin" rdp set-tls-cert "$tls_cert"
"$grdctl_bin" rdp set-tls-key "$tls_key"
"$grdctl_bin" rdp set-credentials "$bridge_user" "$rdp_password"
"$grdctl_bin" rdp disable-view-only
"$grdctl_bin" rdp disable-port-negotiation
"$grdctl_bin" rdp enable'''
if grd in text:
    replacement = '''if [[ "$desktop_relay" == rdp ]]; then
    "$grdctl_bin" rdp set-port "$rdp_port"
    "$grdctl_bin" rdp set-tls-cert "$tls_cert"
    "$grdctl_bin" rdp set-tls-key "$tls_key"
    "$grdctl_bin" rdp set-credentials "$bridge_user" "$rdp_password"
    "$grdctl_bin" rdp disable-view-only
    "$grdctl_bin" rdp disable-port-negotiation
    "$grdctl_bin" rdp enable
fi'''
    text = text.replace(grd, replacement, 1)

store = '''printf '%s' "$rdp_password" | "$secret_tool_bin" store \\
    --label='UU Remote Ubuntu bridge RDP credential' \\
    service uu-desktop-bridge username "$bridge_user"'''
if store in text:
    replacement = '''if [[ "$desktop_relay" == rdp ]]; then
    printf '%s' "$rdp_password" | "$secret_tool_bin" store \\
        --label='UU Remote Ubuntu bridge RDP credential' \\
        service uu-desktop-bridge username "$bridge_user"
fi'''
    text = text.replace(store, replacement, 1)
installer.write_text(text)

text = bridge.read_text()
old = '''    done < <(/usr/bin/pgrep -u "$UID" -x gnome-shell | /usr/bin/sort -nr)'''
if old in text:
    new = '''    done < <(
        {
            /usr/bin/pgrep -u "$UID" -x gnome-shell || true
            /usr/bin/pgrep -u "$UID" -x xfce4-session || true
        } | /usr/bin/sort -nru
    )'''
    text = text.replace(old, new, 1)
elif '/usr/bin/pgrep -u "$UID" -x xfce4-session' not in text:
    raise SystemExit("无法应用 UU Bridge XFCE 会话发现适配")
bridge.write_text(text)
PY
  chown -R "$DESKTOP_USER:$DESKTOP_USER" "$UU_BRIDGE_DIR"

  desktop_uid="$(id -u "$DESKTOP_USER")"
  user_runtime_dir="/run/user/${desktop_uid}"
  for _ in {1..60}; do
    [[ -S "$user_runtime_dir/bus" && -f "$desktop_home/.Xauthority" ]] && break
    sleep 2
  done
  [[ -S "$user_runtime_dir/bus" ]] || die "UU Remote 安装失败：桌面用户的 systemd 会话总线未就绪。"
  [[ -f "$desktop_home/.Xauthority" ]] || die "UU Remote 安装失败：X11 授权文件未就绪。"

  uu_relay_password="${TT_UU_RELAY_PASSWORD:-$(python3 -c 'import secrets; print(secrets.token_hex(16))')}"
  uu_sudoers="/etc/sudoers.d/99-ttlinux-uu-installer"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$DESKTOP_USER" >"$uu_sudoers"
  chmod 0440 "$uu_sudoers"
  trap 'rm -f "$uu_sudoers"' EXIT INT TERM

  set +e
  runuser -u "$DESKTOP_USER" -- env \
    HOME="$desktop_home" USER="$DESKTOP_USER" LOGNAME="$DESKTOP_USER" \
    DISPLAY=:0 XAUTHORITY="$desktop_home/.Xauthority" XDG_SESSION_TYPE=x11 \
    XDG_RUNTIME_DIR="$user_runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${user_runtime_dir}/bus" \
    UURB_RELAY_PASSWORD="$uu_relay_password" \
    "$UU_BRIDGE_DIR/install.sh" \
      --resolution "$SCREEN_MODE" \
      --desktop-target :0 \
      --desktop-relay vnc \
      --keyboard-route x11 \
      --skip-account-login
  uu_install_status=$?
  set -e
  rm -f "$uu_sudoers"
  trap - EXIT INT TERM
  unset uu_relay_password
  (( uu_install_status == 0 )) || die "UU Remote Ubuntu Bridge 安装失败（退出码 ${uu_install_status}）。"

  # Keep the management console available on loopback for first-time UU login.
  runuser -u "$DESKTOP_USER" -- env \
    HOME="$desktop_home" USER="$DESKTOP_USER" XDG_RUNTIME_DIR="$user_runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${user_runtime_dir}/bus" \
    systemctl --user enable --now uu-remote-console.service
fi

public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$public_ip" ]] || public_ip="$(hostname -I | awk '{print $1}')"

printf '\n\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m TT-linux 安装完成\033[0m\n'
printf ' 桌面用户       : %s\n' "$DESKTOP_USER"
printf ' 桌面分辨率     : %s\n' "$SCREEN_MODE"
printf ' Swap           : %s GiB（swappiness=10）\n' "$SWAP_SIZE_GB"
printf ' 远控软件       : %s\n' "$REMOTE_SOFTWARE"
if [[ "$REMOTE_SOFTWARE" == "rustdesk" ]]; then
  rustdesk_id=""
  for _ in {1..60}; do
    rustdesk_id="$(rustdesk --get-id 2>/dev/null | tr -d '\r\n[:space:]' || true)"
    [[ -n "$rustdesk_id" && "$rustdesk_id" != 0 ]] && break
    sleep 2
  done
  [[ -n "$rustdesk_id" ]] || rustdesk_id="（服务仍在注册，请稍后运行 rustdesk --get-id）"
  printf ' RustDesk 设备 ID: %s\n' "$rustdesk_id"
  printf ' IP 直连地址    : %s:%s\n' "$public_ip" "$RUSTDESK_PORT"
else
  printf ' UU 管理控制台  : http://127.0.0.1:6080/vnc.html\n'
  printf ' 首次登录隧道   : ssh -L 6080:127.0.0.1:6080 root@%s\n' "$public_ip"
  printf ' UU 服务状态    : sudo -u %s XDG_RUNTIME_DIR=/run/user/%s systemctl --user status uu-remote-bridge\n' \
    "$DESKTOP_USER" "$(id -u "$DESKTOP_USER")"
fi
printf ' Chrome 启动脚本: %s/Desktop/start-chrome.sh\n' "$desktop_home"
printf '\033[1;32m============================================================\033[0m\n'
