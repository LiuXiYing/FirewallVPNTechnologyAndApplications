#!/bin/bash
# ============================================================
# setup.sh — 防火墙与VPN技术期末大作业：网络环境搭建
# 功能：创建6个network namespace，用veth连接，配置IP和路由
# 运行环境：Linux（需root权限，需iproute2）
# ============================================================

# 不用 set -e，改为手动检查关键步骤
# set -e 在重复运行时会因 "File exists" 而退出

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- 检查root权限 ----
if [ "$EUID" -ne 0 ]; then
  error "请使用 sudo 运行此脚本"
  exit 1
fi

# ---- 检查依赖 ----
for cmd in ip iptables; do
  if ! command -v $cmd &>/dev/null; then
    error "缺少命令: $cmd，请安装 iproute2 和 iptables"
    exit 1
  fi
done

# ---- 清理旧环境 ----
info "清理旧的 namespace..."
for ns in fw office guest dmz internet remote; do
  ip netns del "$ns" 2>/dev/null || true
done

# 删除残留 veth
for veth in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet veth-fw-remote veth-inet-rem veth-remote veth-office veth-guest veth-dmz veth-inet; do
  ip link del "$veth" 2>/dev/null || true
done

# kill 残留的 python3/wireguard-go 进程
for ns in fw office guest dmz internet remote; do
  ip netns exec "$ns" pkill -f "python3 -m http.server" 2>/dev/null || true
  ip netns exec "$ns" pkill -f "wireguard-go" 2>/dev/null || true
done

info "旧环境已清理"

# ============================================================
# 第一部分：创建 namespace
# ============================================================
info "创建 6 个 network namespace..."
for ns in fw office guest dmz internet remote; do
  # 先检查是否已存在
  if ip netns list | grep -q "^${ns}"; then
    warn "namespace $ns 已存在，跳过创建"
  else
    ip netns add "$ns"
  fi
  # 启用 loopback
  ip netns exec "$ns" ip link set lo up
done
info "namespace 创建完成：fw office guest dmz internet remote"

# ============================================================
# 第二部分：创建 veth 对并配置 IP
# ============================================================
info "创建 veth 对并配置 IP..."

# ---- office <--> fw ----
info "  配置 office <-> fw (10.20.0.0/24)"
ip link add veth-fw-office type veth peer name veth-office 2>/dev/null || warn "veth-fw-office 已存在"
ip link set veth-fw-office netns fw
ip link set veth-office netns office
ip netns exec fw     ip addr replace 10.20.0.1/24 dev veth-fw-office
ip netns exec office ip addr replace 10.20.0.2/24 dev veth-office
ip netns exec fw     ip link set veth-fw-office up
ip netns exec office ip link set veth-office up

# ---- guest <--> fw ----
info "  配置 guest <-> fw (10.30.0.0/24)"
ip link add veth-fw-guest type veth peer name veth-guest 2>/dev/null || warn "veth-fw-guest 已存在"
ip link set veth-fw-guest netns fw
ip link set veth-guest netns guest
ip netns exec fw    ip addr replace 10.30.0.1/24 dev veth-fw-guest
ip netns exec guest ip addr replace 10.30.0.2/24 dev veth-guest
ip netns exec fw    ip link set veth-fw-guest up
ip netns exec guest ip link set veth-guest up

# ---- dmz <--> fw ----
info "  配置 dmz <-> fw (10.40.0.0/24)"
ip link add veth-fw-dmz type veth peer name veth-dmz 2>/dev/null || warn "veth-fw-dmz 已存在"
ip link set veth-fw-dmz netns fw
ip link set veth-dmz netns dmz
ip netns exec fw  ip addr replace 10.40.0.1/24 dev veth-fw-dmz
ip netns exec dmz ip addr replace 10.40.0.2/24 dev veth-dmz
ip netns exec fw  ip link set veth-fw-dmz up
ip netns exec dmz ip link set veth-dmz up

# ---- internet <--> fw ----
info "  配置 internet <-> fw (203.0.113.0/24)"
ip link add veth-fw-inet type veth peer name veth-inet 2>/dev/null || warn "veth-fw-inet 已存在"
ip link set veth-fw-inet netns fw
ip link set veth-inet netns internet
ip netns exec fw       ip addr replace 203.0.113.1/24 dev veth-fw-inet
ip netns exec internet ip addr replace 203.0.113.10/24 dev veth-inet
ip netns exec fw       ip link set veth-fw-inet up
ip netns exec internet ip link set veth-inet up

# ---- remote <--> internet (让remote能通过internet到达fw) ----
info "  配置 remote <-> internet (192.0.2.0/24)"
ip link add veth-inet-rem type veth peer name veth-remote 2>/dev/null || warn "veth-inet-rem 已存在"
ip link set veth-inet-rem netns internet
ip link set veth-remote netns remote
ip netns exec internet ip addr replace 192.0.2.1/24 dev veth-inet-rem
ip netns exec remote    ip addr replace 192.0.2.2/24 dev veth-remote
ip netns exec internet ip link set veth-inet-rem up
ip netns exec remote    ip link set veth-remote up

# ============================================================
# 第三部分：配置路由
# ============================================================
info "配置路由..."

# office/guest/dmz 默认路由指向 fw（用 replace 防止重复）
ip netns exec office   ip route replace default via 10.20.0.1
ip netns exec guest    ip route replace default via 10.30.0.1
ip netns exec dmz      ip route replace default via 10.40.0.1

# internet 默认路由指向 fw
ip netns exec internet ip route replace default via 203.0.113.1

# remote 默认路由指向 internet
ip netns exec remote ip route replace default via 192.0.2.1

# internet 需要知道如何回到 remote（192.0.2.0/24）
ip netns exec internet ip route replace 192.0.2.0/24 dev veth-inet-rem

# fw 需要知道如何回到 remote（192.0.2.0/24）
# WireGuard 回包：fw 收到 remote 的握手 UDP 包后，要回包给 192.0.2.2
# 如果没有这条路由，回包被丢弃 → 隧道无法建立
ip netns exec fw ip route replace 192.0.2.0/24 via 203.0.113.10

# ============================================================
# 第四部分：开启 IP 转发
# ============================================================
info "在 fw 上开启 IP 转发..."
ip netns exec fw sysctl -w net.ipv4.ip_forward=1 > /dev/null

# internet 也需要转发（remote要经过internet到达fw）
ip netns exec internet sysctl -w net.ipv4.ip_forward=1 > /dev/null

# ============================================================
# 第五部分：验证基础连通性
# ============================================================
info "========== 基础连通性测试 =========="

echo ""
info "测试 1: office -> fw (10.20.0.1)"
ip netns exec office ping -c 2 -W 2 10.20.0.1 && echo "  -> PASS" || echo "  -> FAIL"

echo ""
info "测试 2: guest -> fw (10.30.0.1)"
ip netns exec guest ping -c 2 -W 2 10.30.0.1 && echo "  -> PASS" || echo "  -> FAIL"

echo ""
info "测试 3: dmz -> fw (10.40.0.1)"
ip netns exec dmz ping -c 2 -W 2 10.40.0.1 && echo "  -> PASS" || echo "  -> FAIL"

echo ""
info "测试 4: internet -> fw (203.0.113.1)"
ip netns exec internet ping -c 2 -W 2 203.0.113.1 && echo "  -> PASS" || echo "  -> FAIL"

echo ""
info "测试 5: remote -> fw 公网IP (203.0.113.1) [需经过internet转发]"
ip netns exec remote ping -c 2 -W 2 203.0.113.1 && echo "  -> PASS" || echo "  -> FAIL"

echo ""
info "========== 环境搭建完成 =========="
info "下一步：运行 firewall.sh 配置防火墙规则"
