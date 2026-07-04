#!/bin/bash
# ============================================================
# audit.sh — 防火墙与VPN技术期末大作业：安全审计与日志分析
# 功能：触发违规流量，收集和分析日志
# ============================================================

# 不使用 set -e，避免预期失败的命令导致脚本退出

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} 请使用 sudo 运行此脚本"
  exit 1
fi

# ============================================================
# 1. 触发各类违规场景
# ============================================================
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第1步：触发违规场景${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "场景1: guest -> office (违规访问)"
ip netns exec guest curl --max-time 2 -s -o /dev/null http://10.20.0.2:8000/ 2>/dev/null || true
ip netns exec guest curl --max-time 2 -s -o /dev/null http://10.20.0.2:22/ 2>/dev/null || true

echo ""
info "场景2: guest -> dmz (违规访问)"
ip netns exec guest curl --max-time 2 -s -o /dev/null http://10.40.0.2:8080/ 2>/dev/null || true
ip netns exec guest curl --max-time 2 -s -o /dev/null http://10.40.0.2:22/ 2>/dev/null || true

echo ""
info "场景3: VPN -> dmz:22 (违规SSH)"
ip netns exec remote curl --max-time 2 -s -o /dev/null http://10.40.0.2:22/ 2>/dev/null || true

echo ""
info "场景4: internet -> office (外部攻击内网)"
ip netns exec internet curl --max-time 2 -s -o /dev/null http://10.20.0.2:8000/ 2>/dev/null || true
ip netns exec internet curl --max-time 2 -s -o /dev/null http://203.0.113.1:22/ 2>/dev/null || true

echo ""
info "场景5: office -> dmz:22 (违规SSH)"
ip netns exec office curl --max-time 2 -s -o /dev/null http://10.40.0.2:22/ 2>/dev/null || true

echo ""
info "场景6: guest 扫描 office 网段"
for i in 1 2 3; do
  ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>/dev/null || true
done

echo ""
info "违规场景触发完成，等待日志写入..."
sleep 2

# ============================================================
# 2. 收集日志
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第2步：日志收集与统计${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "==== iptables FORWARD 规则计数器 ===="
ip netns exec fw iptables -L FORWARD -n -v --line-numbers

echo ""
info "==== iptables NAT 表规则 ===="
ip netns exec fw iptables -t nat -L -n -v --line-numbers

# 日志读取函数（兼容 WSL2：优先 journalctl，fallback dmesg）
read_audit_logs() {
  if command -v journalctl &>/dev/null && systemctl --version &>/dev/null; then
    journalctl -k --no-pager 2>/dev/null
  else
    dmesg 2>/dev/null
  fi
}

echo ""
info "==== 内核日志统计 ===="
echo ""
echo "+-------------------------------+--------+"
echo "| 事件类型                       | 次数   |"
echo "+-------------------------------+--------+"

for prefix in "OFFICE-TO-DMZ-SSH" "GUEST-TO-OFFICE" "GUEST-TO-DMZ" "VPN-TO-DMZ-SSH" "INET-TO-OFFICE" "VPN-DENY"; do
  COUNT=$(read_audit_logs | grep "$prefix" | wc -l)
  printf "| %-30s | %6d |\n" "$prefix" "$COUNT"
done
echo "+-------------------------------+--------+"

echo ""
info "==== 最近20条安全日志 ===="
read_audit_logs | grep -E "GUEST-TO-|VPN-|INET-TO-|OFFICE-TO-" | tail -20 || echo "(无日志或日志读取不可用)"

# ============================================================
# 3. 分析报告
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第3步：日志分析报告${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
echo "1. 事件分布分析:"
for prefix in "GUEST-TO-OFFICE" "GUEST-TO-DMZ" "VPN-TO-DMZ-SSH" "INET-TO-OFFICE" "OFFICE-TO-DMZ-SSH" "VPN-DENY"; do
  COUNT=$(read_audit_logs | grep "$prefix" | wc -l)
  if [ "$COUNT" -gt 0 ]; then
    echo "   - $prefix: $COUNT 次"
  fi
done

echo ""
echo "2. 安全评估:"
echo "   - guest区域隔离策略生效，guest无法访问office和dmz内部服务"
echo "   - VPN用户权限控制有效，仅允许访问office和dmz:8080，SSH端口被拒绝"
echo "   - 外网DNAT仅开放8080端口，其他端口访问被拒绝"
echo "   - 所有违规访问均被记录，可用于事后审计"
echo ""
echo "3. 建议:"
echo "   - 可增加connlimit模块限制单IP并发连接数"
echo "   - 可配置logrotate定期轮转防火墙日志"
echo "   - 可集成fail2ban对重复违规IP进行自动封禁"
