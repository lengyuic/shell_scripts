# Linux VPS 一键配置脚本（多发行版自动识别）

把原本散落的多个脚本（dd 重装 / fail2ban / nftables / sing-box / realm / BBR 调优 / Cloudflare DDNS）整合成一个交互式菜单脚本 **`setup.sh`**，全部 POSIX `sh`，支持 `curl | sh` 一键运行。

脚本启动时**自动识别发行版与包管理器**，安装/卸载逻辑统一走抽象层，无需手动适配：

| 系族 | 代表发行版 | 包管理器 |
|---|---|---|
| debian | Debian / Ubuntu / Kali / Mint | `apt` |
| rhel | RHEL / CentOS / Rocky / AlmaLinux / Fedora / Oracle / Anolis / openEuler | `dnf` / `yum` |
| arch | Arch / Manjaro | `pacman` |
| alpine | Alpine | `apk` |
| suse | openSUSE / SLES | `zypper` |

RHEL 系会在需要时自动启用 EPEL 仓库（fail2ban 依赖），并自动处理 `chrony`/`chronyd` 服务名、`chrony.conf` 路径、`vim-enhanced` 等发行版差异。

## 快速开始

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/setup.sh)"
```

或下载到本地：

```bash
curl -O https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/setup.sh
sudo sh setup.sh
```

## 主菜单

```
1) 安装常用软件
2) 配置 NTP >
3) Fail2Ban >
4) Sing-Box 配置 >
5) 防火墙配置 >
6) TCP 调优 >
7) Realm 配置 >
8) Cloudflare DDNS >
9) SSH 配置 >
10) 系统重装 (DD) ⚠
q) 退出脚本
```

带 `>` 的项是二级菜单，二级菜单内还可能有三级（如增删改查）。所有子菜单顶部默认显示该模块**实时状态**（安装状态 / 服务状态 / 关键参数）。主菜单顶部还会显示识别到的**系统**与**包管理器**。

## 导航约定

所有子菜单统一三档退出：

| 输入 | 含义 |
|---|---|
| `回车` | 返回上层菜单 |
| `m` | 直接返回主菜单（跨层跳） |
| `q` | 退出脚本 |

## 模块说明

### 1) 安装常用软件
一次性装好 `vim` / `git` / `curl` / `wget` / `tar` / `zsh`（RHEL 系自动用 `vim-enhanced`，且只补装缺失的命令以避开 `curl` 与 `curl-minimal` 冲突），并配置 oh-my-zsh（`ys` 主题）+ vim 鼠标禁用。

### 2) NTP (chrony)
状态栏显示：安装 / 启用 / 当前时区 / 当前时间 / NTP 同步状态 + 偏差。

- 安装 / 卸载 / 启用 / 禁用 / 强制同步一次（`chronyc makestep`）
- 详细状态（`chronyc tracking` + `chronyc sources -v`）
- **自定义 NTP 服务器（增删改查）** — 持久化到 `/etc/ntp_servers.conf`，通过 sentinel 块（`# === BEGIN setup.sh CUSTOM SOURCES ===`）写入 `chrony.conf`，不污染原文件
- 自动识别 chrony 的服务名（Debian 系 `chrony` / RHEL 系 `chronyd`）与配置路径（`/etc/chrony/chrony.conf` 或 `/etc/chrony.conf`）

### 3) Fail2Ban
状态栏显示：安装 / 服务 / 启用监狱 / 当前监禁数 / SSH 端口 / 已配置监狱数。

- 安装 / 卸载 / 启用（写 jail.local 并启动）/ 禁用 / 查看监禁状态 / 解封 IP
- **监狱 jail（增删改查）** — 持久化到 `/etc/fail2ban_jails.conf`，启用时按列表生成 `jail.local`
- 内置 jail 模板：`sshd`、`sshd-ddos`、`recidive`，也支持自定义 filter 名（如 `nginx-http-auth`）
- 端口支持 `auto`（自动取当前 sshd 端口）、`all`（recidive 用）、或具体端口号

### 4) Sing-Box
状态栏显示：安装 / 服务 / 当前协议。**完全以 `/etc/sing-box/config.json` 为唯一数据源，不依赖任何缓存文件**。

- 安装 / 卸载 / 配置代理 / **查看代理链接** / 删除代理 / 重启代理
- 支持两种协议：
  - **Shadowsocks-2022**（落地机推荐）
  - **VLESS + Reality**（中转机推荐，自动测延迟选最佳 SNI 域名）
- 查看链接时实时：
  - 取公网 IP（4 个 endpoint 轮询）
  - 用 `openssl` X25519 从 `private_key` 派生 `public_key`
  - 重建 `vless://` / `ss://` 链接 + 客户端 JSON

### 5) 防火墙（nftables 入站白名单）
状态栏显示：安装 / 服务 / 当前 table 总数 / 本脚本 table 是否存在 / 白名单 IP 数。**完全以 live nftables 状态为唯一数据源**，不会影响你手动添加的其他 table（如 `filter`、`nat`）。

- 安装 / 卸载 / 启用（创建 `inet landing_whitelist` 表）/ 禁用（删表）/ 清空全部 nft 规则
- **入站 IP（增删改查）** — 直接 `nft add/delete element inet landing_whitelist admin_ip4`
- 每次 CRUD 自动 `nft list ruleset > /etc/nftables.conf` 持久化（**包含你的其他 table**，重启后整体恢复）
- 白名单为空 + 防火墙开启 → 警告会锁死自己

### 6) TCP 调优（BBR）
状态栏显示：拥塞控制 / 队列算法 / 缓冲上限 / 优化配置状态 / 开机持久化状态。

- **应用 BBR 优化**：交互选择带宽（100 Mbps – 2.5 Gbps，含自定义）+ 延迟（30 ms – 250 ms，含自定义），按 BDP × 2.5 自动算缓冲（4 MB 下限、128 MB 上限）
- **移除 BBR 优化**：清掉 sysctl conf + 卸载持久化 service
- **查看完整 TCP 参数**：dump 关键 sysctl + 每张网卡当前 qdisc
- 配置写到 `/etc/sysctl.d/99-bbr-direct-manual.conf`
- 安装 `bbr-optimize-persist.service` 开机自动恢复 `tc fq` / MSS clamp / initcwnd 32 / RPS

### 7) Realm（TCP/UDP 转发）
状态栏显示：安装 / 二进制路径 / 配置文件路径 / 服务状态 / 转发规则数。**自动检测 `/opt/realm` 与 `/etc/realm` 两个常见路径**。

- 安装（github releases，自动识别 `x86_64` / `aarch64` / `armv7` 架构）/ 卸载 / 启用 / 禁用 / **重启**
- 查看完整配置
- **转发规则（增删改查）** — 直接编辑 TOML 配置，每次操作自动 `.bak.<timestamp>` 备份，修改后若服务在运行则自动 `systemctl restart`

### 8) Cloudflare DDNS
状态栏显示：安装状态 / 域名 / Zone / 记录模式 / CF 代理 / TTL / 自动更新状态 / 最近日志。

- **安装并配置**：输入域名 + API Token（Zone:DNS:Edit 权限），自动向上递归查找 Zone、缺失时自动创建占位 A/AAAA 记录
- 记录模式支持 **仅 IPv4** 或 **IPv4 + IPv6 双栈**，可选 Cloudflare 代理（橙云）与自定义 TTL
- 生成独立的 `/root/ddns.sh` 并写入 crontab（**每 5 分钟自动更新**，IP 未变化则跳过），日志自动截尾保留 500 行
- 立即手动更新一次 / 查看日志（错误红色、成功绿色高亮）/ 暂停・恢复自动更新 / 卸载
- cron 包名按发行版自动适配（Debian 系 `cron` / RHEL・Arch 系 `cronie` / Alpine `dcron`）

### 9) SSH 配置
状态栏显示：端口 / 密码登录 / 密钥登录 / Root 登录 / 已授权密钥数 / 配置方式（drop-in 或主配置）。

- **密钥配置（三级菜单）**：列出 `/root/.ssh/authorized_keys` 中的密钥（类型 + 指纹 + 注释）；支持**粘贴添加公钥**（格式 + `ssh-keygen` 双重校验、自动去重）、**服务器生成 ed25519 密钥对**（公钥自动入库，私钥屏显一次，可选删除服务器留存）、**按序号删除**
- **端口配置**：校验范围与端口占用，`sshd -t` 校验失败自动回滚；改完提示保留当前会话验证、放行安全组、Fail2Ban 重新应用
- **密码登录开关**：按当前状态显示"关闭/开启密码登录"；关闭前强制要求 authorized_keys 至少有一把密钥，需输入 `yes` 确认；自动兼容新旧 OpenSSH（`KbdInteractiveAuthentication` / `ChallengeResponseAuthentication`）
- 配置写入自动适配：存在 `Include sshd_config.d` 时写入 `00-setup-script.conf` drop-in（优先级最高），否则直接改 `sshd_config`；每次修改前自动备份，校验失败回滚
- 安全兜底：密码登录已关闭时禁止删除最后一把密钥

### 10) 系统重装（DD）
集成 [bin456789/reinstall](https://github.com/bin456789/reinstall)，覆盖以下系统：

| 系统 | 版本 |
|---|---|
| debian | 9 / 10 / 11 / 12 / 13 |
| ubuntu | 18.04 / 20.04 / 22.04 / 24.04 / 26.04（可选 `--minimal`）|
| centos | 9 / 10 |
| rocky / almalinux / oracle | 8 / 9 / 10 |
| fedora | 43 / 44 |
| anolis | 7 / 8 / 23 |
| opencloudos | 8 / 9 / 23 |
| openeuler | 20.03 / 22.03 / 24.03 |
| alpine | 3.20 / 3.21 / 3.22 / 3.23 |
| opensuse | 16.0 / tumbleweed |
| nixos | 25.11 |
| fnos | 1 |
| arch / kali / gentoo / aosc | 无版本 |
| redhat | 需要 qcow2 镜像 URL |

交互流程：

```
选系统 → 选版本(若有) → [ubuntu 额外问 --minimal] → SSH 端口(默认沿用当前)
       → SSH 公钥(留空回退到 /root/.ssh/authorized_keys 第一行)
       → 摘要展示 → y/n 确认 → 下载 reinstall.sh → 执行
```

公钥缺失会**拒绝执行**（避免重装后无法登录）。reinstall.sh 完成后不会自动重启，需手动 `reboot` 进入新系统。

## 文件清单

| 路径 | 用途 |
|---|---|
| `/etc/sing-box/config.json` | Sing-Box 配置（Sing-Box 模块的唯一数据源）|
| `/etc/ntp_servers.conf` | 自定义 NTP 服务器列表 |
| `/etc/chrony/chrony.conf` 或 `/etc/chrony.conf` | chrony 主配置（按发行版自动识别，脚本通过 sentinel 块注入自定义源）|
| `/etc/fail2ban_jails.conf` | Fail2Ban 监狱清单 |
| `/etc/fail2ban/jail.local` | 启用 Fail2Ban 时自动生成 |
| `/etc/nftables.conf` | nft 规则持久化（含手动添加的其他 table）|
| `/etc/sysctl.d/99-bbr-direct-manual.conf` | BBR + TCP 调优 sysctl |
| `/etc/systemd/system/bbr-optimize-persist.service` | BBR 开机持久化 service |
| `/usr/local/bin/bbr-optimize-apply.sh` | BBR 开机执行脚本 |
| `/etc/realm/config.toml` 或 `/opt/realm/config.toml` | Realm 配置（Realm 模块的唯一数据源）|
| `/etc/systemd/system/realm.service` | Realm systemd service（新装时创建）|
| `/root/ddns.sh` | DDNS 更新脚本（crontab 每 5 分钟执行）|
| `/root/.cf_token` | Cloudflare API Token（权限 600）|
| `/root/.cf_zone` | DDNS 配置（域名 / Zone / 模式 / TTL）|
| `/var/log/ddns.log` | DDNS 更新日志（自动截尾 500 行）|
| `/etc/ssh/sshd_config.d/00-setup-script.conf` | SSH 模块写入的 drop-in 配置（系统支持 Include 时）|
| `/root/.ssh/authorized_keys` | SSH 授权公钥（密钥配置的唯一数据源）|

## 依赖

- 系统：基于 **systemd** 的主流发行版 —— Debian/Ubuntu、RHEL/CentOS/Rocky/AlmaLinux/Fedora、Arch、openSUSE 等（已识别 `apt`/`dnf`/`yum`/`pacman`/`apk`/`zypper`）
- 必备工具：`curl`、`openssl`、`systemctl`、`awk`、`sed`
- 按需自动安装：`chrony`、`fail2ban`、`nftables`、`realm`、`python3`、`tar`、`cron`（DDNS 用，按发行版选 `cron`/`cronie`/`dcron`）

`python3` 在 Sing-Box 查看链接和 DDNS 解析 Cloudflare API 响应时使用，脚本会按需调用对应包管理器安装。

> 备注：脚本逻辑面向 systemd 发行版。Alpine 等使用 OpenRC（非 systemd）的系统能完成软件安装，但 `systemctl` 相关的服务启停/状态功能可能不适用。

## 设计要点

1. **多数据源驱动而非缓存**：Sing-Box 直接读 `config.json`，防火墙直接读 live nft 状态，Realm 直接读 TOML 配置 —— 即使用户绕过本脚本手动改了配置，下次进菜单仍能正确显示。
2. **不污染既有配置**：防火墙不 `flush ruleset` 重写（用增量 `nft add/delete element`），NTP 用 sentinel 块写 chrony.conf，Realm 不强制搬迁用户已有 config。
3. **多级菜单状态可见**：每个子菜单进入时顶部展示该模块状态，无需额外操作。
4. **统一退出语义**：所有子菜单 `回车/m/q` 一致，`m` 能从任意层级跨层跳回主菜单。
5. **多发行版抽象**：启动时 `detect_os` 识别系族与包管理器，安装/卸载统一走 `pkg_install`/`pkg_remove`/`pkg_update` 封装，服务名与配置路径按发行版动态解析，无需为每个发行版维护分支逻辑。
