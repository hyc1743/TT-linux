# TT-linux

在无显示器的 Ubuntu/Debian Linux 服务器上，一键部署可 24 小时运行的图形桌面：

- Xfce 桌面与 LightDM 自动登录
- Xorg Dummy 显示驱动，可选 **1600×900、1920×1080、2560×1440**，默认 **1920×1080**
- Google Chrome Stable（中文字体、解除跨域限制、`nofile=65535`）
- RustDesk（永久密码、设备 ID、IP 直连）
- 关闭锁屏、屏保、DPMS、睡眠与休眠

## 支持环境

- Ubuntu 22.04 / 24.04（amd64）
- Debian 系 amd64 发行版亦可尝试
- 必须以 `root` 运行

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/hyc1743/TT-linux/main/install.sh | bash
```

安装过程中会以隐藏输入方式要求设置 RustDesk 永久密码，并提供桌面分辨率选项：

1. `1600x900`
2. `1920x1080`（默认，直接回车即可）
3. `2560x1440`

完成后终端会输出：

- RustDesk 设备 ID
- RustDesk IP 直连地址（TCP 21118）
- Chrome 桌面启动脚本路径

非交互部署可使用环境变量：

```bash
curl -fsSL https://raw.githubusercontent.com/hyc1743/TT-linux/main/install.sh -o /tmp/tt-linux-install.sh
RUSTDESK_PASSWORD='你的永久密码' TT_SCREEN_MODE='1920x1080' bash /tmp/tt-linux-install.sh
```

非交互运行未指定 `TT_SCREEN_MODE` 时同样默认使用 `1920x1080`。

## Chrome 启动方式

安装脚本会在 `ttlinux` 用户桌面生成：

- `start-chrome.sh`：实际启动脚本
- `Chrome-TT.desktop`：双击启动入口

启动参数包含独立用户数据目录和 `--disable-web-security`。脚本会把 Chrome 的 soft `nofile` 上限提高至 65535（不超过系统 hard limit）。可向脚本追加网址或其他 Chrome 参数：

```bash
~/Desktop/start-chrome.sh https://example.com
```

## 运维检查

```bash
# RustDesk 设备 ID与服务状态
rustdesk --get-id
systemctl status rustdesk --no-pager

# 图形会话、分辨率和防休眠状态
DISPLAY=:0 xrandr --current
systemctl status lightdm --no-pager
systemctl status sleep.target suspend.target hibernate.target

# RustDesk IP 直连监听端口
ss -lntp | grep 21118
```

云服务器还需在云平台安全组入方向开放 **TCP 21118**，才能从公网使用 `服务器IP:21118` 直连。
