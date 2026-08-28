# TT-linux

在无显示器的 Ubuntu/Debian Linux 服务器上，一键部署可 24 小时运行的图形桌面：

- Xfce 桌面与 LightDM 自动登录
- Xorg Dummy 显示驱动，可选 **1600×900、1920×1080、2560×1440**，默认 **1920×1080**
- Google Chrome Stable（中文字体、解除跨域限制、`nofile=65535`）
- 远控软件可安装 **UU Remote**、**RustDesk** 或同时安装两者
- 默认创建 4 GiB Swap，并设置 `vm.swappiness=10`
- 关闭锁屏、屏保、DPMS、睡眠与休眠
- 关闭 Xfce 桌面合成器，降低远程桌面重绘开销
- 禁止 Xfce Power Manager 后台进程自动启动
- 限制 journald 持久日志为 200 MiB、运行时日志为 100 MiB，最多保留 7 天
- 关闭 Core Dump 及 Ubuntu Apport/Whoopsie 错误报告服务

## 支持环境

- RustDesk 方案：Ubuntu 22.04 / 24.04（amd64）
- UU Remote 方案：Ubuntu 22.04 / 24.04（amd64）
- Debian 系 amd64 发行版亦可尝试
- 必须以 `root` 运行

UU Remote 使用 [uu-remote-ubuntu-bridge](https://github.com/lachlanchen/uu-remote-ubuntu-bridge) 的固定审计版本。TT-linux 增加 Ubuntu 22.04、XFCE/X11 会话发现适配，并使用其仅监听本机的 VNC 中继；原有 Xfce、LightDM、Xorg Dummy 桌面方案保持不变。Ubuntu 22.04 自动使用仓库中的 `freerdp2-x11`，Ubuntu 24.04 使用 `freerdp3-x11`。该桥接器会安装 WineHQ 和编译依赖，首次安装耗时和磁盘占用会明显高于 RustDesk。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/hyc1743/TT-linux/main/install.sh -o /tmp/tt-linux-install.sh && bash /tmp/tt-linux-install.sh
```

先下载再执行可以为密码和分辨率选择保留终端输入；请勿使用 `curl ... | bash`，部分 Web SSH 控制台不会为管道中的脚本提供可交互的 `/dev/tty`。

安装过程中首先选择远控软件：

1. `UU Remote`（Ubuntu 22.04 / 24.04）
2. `RustDesk`（默认）
3. 同时安装 `UU Remote` 和 `RustDesk`

选择 RustDesk 或同时安装两者时，会以隐藏输入方式要求设置 RustDesk 永久密码。所有方案都会提供桌面分辨率选项：

1. `1600x900`
2. `1920x1080`（默认，直接回车即可）
3. `2560x1440`

安装完成后会检测并输出当前已安装的全部远控软件信息。选择一个方案不会卸载另一个方案，因此可以直接重新执行脚本进行追加安装：

- 旧版本已经安装 RustDesk：重新执行并选择 `UU Remote`，即可保留 RustDesk 并增加 UU Remote。
- 已经安装 UU Remote：重新执行并选择 `RustDesk`，即可保留 UU Remote 并增加 RustDesk。
- 两者均未安装：可以直接选择“同时安装”。

检测到 RustDesk 时，终端会输出：

- RustDesk 设备 ID
- RustDesk IP 直连地址（TCP 21118）
- Chrome 桌面启动脚本路径

非交互部署可使用环境变量：

```bash
curl -fsSL https://raw.githubusercontent.com/hyc1743/TT-linux/main/install.sh -o /tmp/tt-linux-install.sh
TT_REMOTE=rustdesk RUSTDESK_PASSWORD='你的永久密码' \
  TT_SCREEN_MODE='1920x1080' TT_SWAP_SIZE_GB=4 \
  bash /tmp/tt-linux-install.sh
```

UU Remote 非交互安装：

```bash
TT_REMOTE=uu-remote TT_SCREEN_MODE='1920x1080' TT_SWAP_SIZE_GB=4 \
  bash /tmp/tt-linux-install.sh
```

同时安装两者：

```bash
TT_REMOTE=both RUSTDESK_PASSWORD='你的永久密码' \
  TT_SCREEN_MODE='1920x1080' TT_SWAP_SIZE_GB=4 \
  bash /tmp/tt-linux-install.sh
```

`TT_REMOTE` 支持 `uu-remote`、`rustdesk` 或 `both`。非交互运行未指定时为兼容旧用法默认选择 RustDesk，未指定 `TT_SCREEN_MODE` 时默认使用 `1920x1080`。无论选择哪个值，脚本都不会主动卸载已经存在的另一套远控软件。

## UU Remote 首次登录

首次安装 UU Remote 时，脚本会临时启动公网登录控制台并监听：

```text
0.0.0.0:6080
```

按照终端提示，在云服务器安全组中临时放行 **TCP 6080**，然后直接在任意电脑或手机浏览器访问：

```text
http://服务器公网IP:6080/vnc.html?autoconnect=1&resize=scale&reconnect=1
```

在页面内完成网易 UU 账号登录和设备绑定，然后回到 SSH 安装终端按 Enter。脚本会立即：

1. 停止并禁用公网 noVNC 控制台服务；
2. 删除 `0.0.0.0` 监听配置；
3. 删除由脚本临时添加的 UFW 6080 规则。

随后还需要在云平台安全组中删除临时的 TCP 6080 入站规则。UU 的桌面中继仍然只在服务器本机运行，`uu-remote-bridge.service` 会随 `ttlinux` 自动登录会话启动。

重新执行安装时，如果检测到 UU Remote 已存在，默认不会再次开放登录端口。需要重新认证时使用：

```bash
TT_REMOTE=uu-remote TT_UU_PUBLIC_LOGIN=on bash /tmp/tt-linux-install.sh
```

自动化安装无法等待人工认证时可以设置 `TT_UU_PUBLIC_LOGIN=off`，跳过临时公网登录步骤。

脚本当前固定使用上游提交 `75405e83a6ce0ac5b588aeead54cfa234d192edb`，避免未经适配的上游更新直接改变已验证的二进制补丁和运行路径。

## Swap 设置

脚本默认创建 `/swapfile`，容量为 4 GiB。对于使用 Chrome 进行 24 小时网页挂机的 8 GiB 内存服务器，这是兼顾磁盘占用和防止 OOM 的推荐值。脚本将 `vm.swappiness` 设置为 `10`，让系统优先使用物理内存。

可以在执行前通过 `TT_SWAP_SIZE_GB` 调整为 1～64 GiB，例如：

```bash
TT_SWAP_SIZE_GB=8 bash /tmp/tt-linux-install.sh
```

重复执行安装脚本时，如果 `/swapfile` 容量已经符合要求，则不会重新创建。

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
# RustDesk 方案：设备 ID 与服务状态
rustdesk --get-id
systemctl status rustdesk --no-pager

# UU Remote 方案：用户服务与日志
uid=$(id -u ttlinux)
sudo -u ttlinux XDG_RUNTIME_DIR=/run/user/$uid \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
  systemctl --user status uu-remote-bridge --no-pager
sudo -u ttlinux XDG_RUNTIME_DIR=/run/user/$uid \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
  journalctl --user -u uu-remote-bridge -n 100 --no-pager

# 图形会话、分辨率和防休眠状态
DISPLAY=:0 xrandr --current
systemctl status lightdm --no-pager
systemctl status sleep.target suspend.target hibernate.target

# Swap 容量和使用策略
swapon --show
sysctl vm.swappiness

# RustDesk 方案：IP 直连监听端口
ss -lntp | grep 21118
```

只有 RustDesk 方案需要在云平台安全组入方向开放 **TCP 21118**，才能从公网使用 `服务器IP:21118` 直连。UU Remote 方案不需要开放该端口。
