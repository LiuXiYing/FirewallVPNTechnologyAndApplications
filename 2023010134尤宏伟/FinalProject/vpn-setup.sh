#!/bin/bash
# ============================================================
# vpn-setup.sh — 防火墙与VPN技术期末大作业：WireGuard VPN 配置
# 功能：生成密钥，创建配置文件，启动WireGuard隧道
# 运行环境：先执行 setup.sh 和 firewall.sh 后运行
# 依赖：wireguard-tools (wg, wg-quick) 或 wireguard-go
# ============================================================

# 不用 set -e，因为有些步骤需要容错（如 wireguard 接口可能已存在）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  error "请使用 sudo 运行此脚本"
  exit 1
fi

# ---- 检查 wireguard ----
if ! command -v wg &>/dev/null; then
  error "缺少 wireguard-tools，请安装：sudo apt install wireguard-tools"
  exit 1
fi

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_DIR="$WORK_DIR/keys"
CONF_DIR="$WORK_DIR/conf"

mkdir -p "$KEY_DIR" "$CONF_DIR"
chmod 700 "$KEY_DIR"

# ============================================================
# 0. 清理旧的 WireGuard 接口（如果有）
# ============================================================
info "清理旧的 WireGuard 接口..."
ip netns exec fw ip link del wg0 2>/dev/null || true
ip netns exec remote ip link del wg0 2>/dev/null || true
# kill 可能残留的 wireguard-go 进程
ip netns exec fw pkill -f "wireguard-go" 2>/dev/null || true
ip netns exec remote pkill -f "wireguard-go" 2>/dev/null || true
sleep 1
info "旧接口已清理"

# ============================================================
# 1. 生成密钥对
# ============================================================
info "生成 WireGuard 密钥对..."

umask 077
# 总是重新生成密钥（避免旧密钥与清理后的环境不匹配）
wg genkey > "$KEY_DIR/fw.key"
cat "$KEY_DIR/fw.key" | wg pubkey > "$KEY_DIR/fw.pub"
info "  fw 密钥已生成"

wg genkey > "$KEY_DIR/remote.key"
cat "$KEY_DIR/remote.key" | wg pubkey > "$KEY_DIR/remote.pub"
info "  remote 密钥已生成"

FW_PRIVATE_KEY=$(cat "$KEY_DIR/fw.key")
FW_PUBLIC_KEY=$(cat "$KEY_DIR/fw.pub")
REMOTE_PRIVATE_KEY=$(cat "$KEY_DIR/remote.key")
REMOTE_PUBLIC_KEY=$(cat "$KEY_DIR/remote.pub")

# ============================================================
# 2. 生成 fw 端配置
# ============================================================
info "生成 fw 端 WireGuard 配置..."
cat > "$CONF_DIR/vpn-fw.conf" <<EOF
[Interface]
PrivateKey = ${FW_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${REMOTE_PUBLIC_KEY}
AllowedIPs = 10.10.10.2/32
PersistentKeepalive = 25
EOF
chmod 600 "$CONF_DIR/vpn-fw.conf"
info "  配置文件: $CONF_DIR/vpn-fw.conf"

# ============================================================
# 3. 生成 remote 端配置
# ============================================================
info "生成 remote 端 WireGuard 配置..."
cat > "$CONF_DIR/vpn-remote.conf" <<EOF
[Interface]
PrivateKey = ${REMOTE_PRIVATE_KEY}

[Peer]
PublicKey = ${FW_PUBLIC_KEY}
Endpoint = 203.0.113.1:51820
# 必须包含 10.10.10.0/24，否则 remote 无法通过隧道访问 fw 的 VPN IP (10.10.10.1)
AllowedIPs = 10.10.10.0/24, 10.20.0.0/24, 10.40.0.0/24
PersistentKeepalive = 25
EOF
chmod 600 "$CONF_DIR/vpn-remote.conf"
info "  配置文件: $CONF_DIR/vpn-remote.conf"

# ============================================================
# 4. 在 fw namespace 中创建 WireGuard 接口
# ============================================================
info "在 fw namespace 中启动 WireGuard..."

# 确保 /dev/net/tun 存在（wireguard-go 需要）
if [ ! -e /dev/net/tun ]; then
    warn "/dev/net/tun 不存在，尝试创建..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

USE_WG_GO=false

# 先尝试内核原生 wireguard
if ip netns exec fw ip link add wg0 type wireguard 2>/dev/null; then
    info "使用内核原生 WireGuard 创建 fw 端 wg0"
else
    warn "内核原生 wireguard 不可用，尝试 wireguard-go..."
    if command -v wireguard-go &>/dev/null; then
        USE_WG_GO=true
        info "使用 wireguard-go 创建 fw 端 wg0..."
        ip netns exec fw wireguard-go -f wg0 &
        FW_WG_PID=$!
        info "wireguard-go fw PID: $FW_WG_PID"
        sleep 2
        # 验证 wg0 是否出现
        if ! ip netns exec fw ip link show wg0 &>/dev/null; then
            error "wireguard-go 创建 wg0 失败"
            exit 1
        fi
    else
        error "内核 wireguard 不可用且未安装 wireguard-go"
        error "请运行: sudo bash wsl2-install.sh"
        exit 1
    fi
fi

# 设置 VPN IP（用 replace 防止已存在报错）
ip netns exec fw ip addr replace 10.10.10.1/24 dev wg0

# 应用配置
ip netns exec fw wg setconf wg0 "$CONF_DIR/vpn-fw.conf"

# 启动接口
ip netns exec fw ip link set wg0 up

info "fw 端 wg0 接口已启动"

# ============================================================
# 5. 在 remote namespace 中创建 WireGuard 接口
# ============================================================
info "在 remote namespace 中启动 WireGuard..."

# 确保 /dev/net/tun 存在
if [ ! -e /dev/net/tun ]; then
    warn "/dev/net/tun 不存在，尝试创建..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

USE_WG_GO_REMOTE=false

if ip netns exec remote ip link add wg0 type wireguard 2>/dev/null; then
    info "使用内核原生 WireGuard 创建 remote 端 wg0"
else
    warn "内核原生 wireguard 不可用，尝试 wireguard-go..."
    if command -v wireguard-go &>/dev/null; then
        USE_WG_GO_REMOTE=true
        info "使用 wireguard-go 创建 remote 端 wg0..."
        ip netns exec remote wireguard-go -f wg0 &
        REMOTE_WG_PID=$!
        info "wireguard-go remote PID: $REMOTE_WG_PID"
        sleep 2
        if ! ip netns exec remote ip link show wg0 &>/dev/null; then
            error "wireguard-go 创建 remote wg0 失败"
            exit 1
        fi
    else
        error "内核 wireguard 不可用且未安装 wireguard-go"
        exit 1
    fi
fi

# 设置 VPN IP
ip netns exec remote ip addr replace 10.10.10.2/24 dev wg0

# 应用配置
ip netns exec remote wg setconf wg0 "$CONF_DIR/vpn-remote.conf"

# 启动接口
ip netns exec remote ip link set wg0 up

# 添加路由：通过 VPN 隧道访问内网（用 replace 防止重复）
ip netns exec remote ip route replace 10.20.0.0/24 dev wg0
ip netns exec remote ip route replace 10.40.0.0/24 dev wg0

info "remote 端 wg0 接口已启动"

# 保存 wireguard-go 进程 PID 以便后续清理
if [ "$USE_WG_GO" = true ] || [ "$USE_WG_GO_REMOTE" = true ]; then
    echo "fw_wireguard-go ${FW_WG_PID:-none}" > "$WORK_DIR/.wg_go_pids"
    echo "remote_wireguard-go ${REMOTE_WG_PID:-none}" >> "$WORK_DIR/.wg_go_pids"
fi

# ============================================================
# 6. 等待握手 + 验证隧道状态
# ============================================================
info "检查 fw 到 remote 公网网段的路由..."
if ip netns exec fw ip route show | grep -q "192.0.2.0/24"; then
    info "  fw -> 192.0.2.0/24 路由已存在"
else
    warn "  fw -> 192.0.2.0/24 路由不存在，尝试重新添加"
    ip netns exec fw ip route replace 192.0.2.0/24 via 203.0.113.10
fi

info "检查 fw 是否监听 UDP 51820..."
ip netns exec fw ss -ulnp 2>/dev/null | grep 51820 || \
    ip netns exec fw netstat -ulnp 2>/dev/null | grep 51820 || \
    warn "  未检测到 UDP 51820 监听（可能 wireguard 使用原始套接字，不影响功能）"

info "等待 WireGuard 隧道握手..."
sleep 3

# 尝试触发握手，最多重试 3 次
HANDSHAKE_OK=false
for i in 1 2 3; do
    info "触发握手 (尝试 $i/3)：remote -> fw (ping 10.10.10.1)"
    if ip netns exec remote ping -c 1 -W 5 10.10.10.1 >/dev/null 2>&1; then
        info "  握手成功！"
        HANDSHAKE_OK=true
        break
    fi
    sleep 2
    info "  检查 wg show 状态..."
    ip netns exec remote wg show 2>/dev/null | grep -E "latest handshake|transfer" || true
done

if [ "$HANDSHAKE_OK" = false ]; then
    warn "VPN 隧道 ping 失败，可能 wireguard-go 工作异常或路由配置错误"
fi

echo ""
info "========== WireGuard 隧道状态 =========="
echo ""
info "fw 端 wg show:"
ip netns exec fw wg show 2>/dev/null || warn "wg show 失败"

echo ""
info "remote 端 wg show:"
ip netns exec remote wg show 2>/dev/null || warn "wg show 失败"

echo ""
info "fw 端 wg0 接口信息:"
ip netns exec fw ip addr show wg0 2>/dev/null || warn "wg0 不存在"

echo ""
info "remote 端 wg0 接口信息:"
ip netns exec remote ip addr show wg0 2>/dev/null || warn "wg0 不存在"

echo ""
info "fw 端路由表（重点看 192.0.2.0/24）:"
ip netns exec fw ip route

echo ""
info "remote 端路由表:"
ip netns exec remote ip route

echo ""
info "vpn-fw.conf:"
cat "$CONF_DIR/vpn-fw.conf"

echo ""
info "vpn-remote.conf:"
cat "$CONF_DIR/vpn-remote.conf"

echo ""
info "========== VPN 配置完成 =========="
info "可以运行 test.sh 进行完整测试"