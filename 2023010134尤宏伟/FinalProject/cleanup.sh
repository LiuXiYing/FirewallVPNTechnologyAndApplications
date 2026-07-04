#!/bin/bash
# cleanup.sh — 清理所有实验环境
# 功能：终止所有进程、删除 namespace、veth、iptables 规则
# ============================================================

# 不用 set -e，清理脚本应尽量多删，不因单项失败退出

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} 请使用 sudo 运行此脚本"
  exit 1
fi

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"

info "开始清理..."

# ---- 1. 终止 wireguard-go 进程 ----
if [ -f "$WORK_DIR/.wg_go_pids" ]; then
    while read -r line; do
        PID=$(echo "$line" | awk '{print $NF}')
        if [ -n "$PID" ] && [ "$PID" != "none" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
            info "已终止 wireguard-go 进程: $PID"
        fi
    done < "$WORK_DIR/.wg_go_pids"
    rm -f "$WORK_DIR/.wg_go_pids"
fi

# 在所有 namespace 中查找并终止 wireguard-go
for ns in fw office guest dmz internet remote; do
    ip netns exec "$ns" pkill -f "wireguard-go" 2>/dev/null || true
done

# ---- 2. 终止 HTTP 服务进程 ----
for ns in fw office guest dmz internet remote; do
    ip netns exec "$ns" pkill -f "python3 -m http.server" 2>/dev/null || true
    ip netns exec "$ns" pkill tcpdump 2>/dev/null || true
done
sleep 1

# ---- 3. 删除 WireGuard 接口 ----
for ns in fw remote; do
    ip netns exec "$ns" ip link del wg0 2>/dev/null || true
done

# ---- 4. 删除 namespace（会自动删除其中的 veth 和接口）----
for ns in fw office guest dmz internet remote; do
    if ip netns del "$ns" 2>/dev/null; then
        info "已删除 namespace: $ns"
    else
        warn "namespace $ns 不存在或已删除"
    fi
done

# ---- 5. 删除主机的残留 veth ----
for veth in veth-fw-office veth-fw-guest veth-fw-dmz veth-fw-inet veth-fw-remote veth-inet-rem veth-office veth-guest veth-dmz veth-inet veth-remote; do
    ip link del "$veth" 2>/dev/null && info "已删除 veth: $veth" || true
done

# ---- 6. 清理 iptables（主机层面，以防万一）----
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -X 2>/dev/null || true

# ---- 7. 确认清理结果 ----
echo ""
info "清理结果确认:"
REMAINING=$(ip netns list 2>/dev/null | wc -l)
if [ "$REMAINING" -eq 0 ]; then
    info "所有 namespace 已清除 ✓"
else
    warn "仍有 $REMAINING 个 namespace 残留"
    ip netns list
fi

echo ""
info "清理完成"
info "可以重新运行: sudo bash run-all.sh"
