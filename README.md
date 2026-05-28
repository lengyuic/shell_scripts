# Debian / Ubuntu VPS 一键配置脚本

把原本散落的多个脚本（dd 重装 / fail2ban / nftables / sing-box / realm / BBR 调优）整合成一个交互式菜单脚本 **`setup.sh`**，全部 POSIX `sh`，支持 `curl | sh` 一键运行。

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
8) 系统重装 (DD) ⚠
q) 退出脚本
```

带 `>` 的项是二级菜单，二级菜单内还可能有三级（如增删改查）。所有子菜单顶部默认显示该模块**实时状态**（安装状态 / 服务状态 / 关键参数）。

## 导航约定

所有子菜单统一三档退出：

| 输入 | 含义 |
|---|---|
| `0` | 返回上层菜单 |
| `00` | 直接返回主菜单（跨层跳） |
| `q` | 退出脚本 |

## 模块说明

### 1) 安装常用软件
一次性装好 `vim` / `git` / `curl` / `wget` / `tar` / `zsh`，并配置 oh-my-zsh（`ys` 主题）+ vim 鼠标禁用。

### 2) NTP (chrony)
状态栏显示：安装 / 启用 / 当前时区 / 当前时间 / NTP 同步状态 + 偏差。

- 安装 / 卸载 / 启用 / 禁用 / 强制同步一次（`chronyc makestep`）
- 详细状态（`chronyc tracking` + `chronyc sources -v`）
- **自定义 NTP 服务器（增删改查）** — 持久化到 `/etc/ntp_servers.conf`，通过 sentinel 块（`# === BEGIN setup.sh CUSTOM SOURCES ===`）写入 `chrony.conf`，不污染原文件

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

### 8) 系统重装（DD）
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
| `/etc/chrony/chrony.conf` | chrony 主配置（脚本通过 sentinel 块注入自定义源）|
| `/etc/fail2ban_jails.conf` | Fail2Ban 监狱清单 |
| `/etc/fail2ban/jail.local` | 启用 Fail2Ban 时自动生成 |
| `/etc/nftables.conf` | nft 规则持久化（含手动添加的其他 table）|
| `/etc/sysctl.d/99-bbr-direct-manual.conf` | BBR + TCP 调优 sysctl |
| `/etc/systemd/system/bbr-optimize-persist.service` | BBR 开机持久化 service |
| `/usr/local/bin/bbr-optimize-apply.sh` | BBR 开机执行脚本 |
| `/etc/realm/config.toml` 或 `/opt/realm/config.toml` | Realm 配置（Realm 模块的唯一数据源）|
| `/etc/systemd/system/realm.service` | Realm systemd service（新装时创建）|

## 依赖

- 系统：Debian 11+ / Ubuntu 20.04+（其他基于 systemd + apt 的发行版可能也能跑）
- 必备工具：`curl`、`openssl`、`systemctl`、`awk`、`sed`
- 按需自动安装：`chrony`、`fail2ban`、`nftables`、`realm`、`python3`、`tar`

`python3` 仅在 Sing-Box 查看链接时用于解析 `config.json`，脚本会按需 `apt install`。

## 设计要点

1. **多数据源驱动而非缓存**：Sing-Box 直接读 `config.json`，防火墙直接读 live nft 状态，Realm 直接读 TOML 配置 —— 即使用户绕过本脚本手动改了配置，下次进菜单仍能正确显示。
2. **不污染既有配置**：防火墙不 `flush ruleset` 重写（用增量 `nft add/delete element`），NTP 用 sentinel 块写 chrony.conf，Realm 不强制搬迁用户已有 config。
3. **多级菜单状态可见**：每个子菜单进入时顶部展示该模块状态，无需额外操作。
4. **统一退出语义**：所有子菜单 `0/00/q` 一致，三级菜单的 `00` 能跨层跳回主菜单。
