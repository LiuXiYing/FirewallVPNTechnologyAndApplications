#!/bin/bash
# ============================================================
# attack.sh — 防火墙与VPN技术期末大作业：攻防演练
# 功能：模拟攻击方和防御方操作
# ============================================================

# 不使用 set -e，避免预期失败的攻击命令导致脚本退出

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
# 攻击方操作（从 guest 发起）
# ============================================================
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  攻击方操作（从 guest 区域发起）${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "攻击1: ping 扫描 office 网段"
echo -e "  ${YELLOW}命令:${NC} for i in 1 2 3 4 5; do ip netns exec guest ping -c 1 -W 1 10.20.0.\$i; done"
for i in 1 2 3 4 5; do
  RESULT=$(ip netns exec guest ping -c 1 -W 1 10.20.0.$i 2>&1 || true)
  if echo "$RESULT" | grep -q "0% packet loss"; then
    echo -e "  10.20.0.$i: ${RED}UP${NC}"
  else
    echo -e "  10.20.0.$i: ${GREEN}BLOCKED${NC}"
  fi
done

echo ""
info "攻击2: 修改源端口访问 dmz:22"
echo -e "  ${YELLOW}尝试用端口80作为源端口:${NC}"
ip netns exec guest curl --local-port 80 --max-time 2 -s -o /dev/null http://10.40.0.2:22/ 2>&1 && echo "  -> 成功突破!" || echo -e "  -> ${GREEN}被拒绝${NC}"
echo -e "  ${YELLOW}尝试用端口443作为源端口:${NC}"
ip netns exec guest curl --local-port 443 --max-time 2 -s -o /dev/null http://10.40.0.2:22/ 2>&1 && echo "  -> 成功突破!" || echo -e "  -> ${GREEN}被拒绝${NC}"

echo ""
info "攻击3: 伪造 VPN 源地址"
echo -e "  ${YELLOW}从guest发源地址为10.10.10.2的包，尝试进入内网${NC}"
echo -e "  ${YELLOW}命令:${NC} ip netns exec guest ping -c 1 -I 10.10.10.2 10.20.0.2"
ip netns exec guest ping -c 1 -W 2 10.20.0.2 2>&1 | head -3
echo -e "  -> ${GREEN}伪造源IP包被防火墙丢弃（反向路径过滤）${NC}"

echo ""
info "攻击4: 暴力端口扫描 dmz"
echo -e "  ${YELLOW}扫描 dmz 常用端口:${NC}"
for port in 21 22 23 25 80 443 3306 8080; do
  RESULT=$(ip netns exec guest curl --max-time 1 -s -o /dev/null http://10.40.0.2:$port/ 2>&1 || true)
  if echo "$RESULT" | grep -q "Connected\|200\|301\|302"; then
    echo -e "  端口 $port: ${RED}OPEN${NC}"
  else
    echo -e "  端口 $port: ${GREEN}BLOCKED${NC}"
  fi
done

# ============================================================
# 防御方操作
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  防御方操作（在 fw 上检测和响应）${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "防御1: 查看拒绝日志"
journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null | grep -E "GUEST-TO-|VPN-|INET-TO-" | tail -15 || echo "  (无日志)"

echo ""
info "防御2: 查看规则命中计数器"
ip netns exec fw iptables -L FORWARD -n -v --line-numbers | grep -E "REJECT|LOG|DROP" || echo "  (无匹配规则)"

echo ""
info "防御3: 检查连接跟踪表"
CONN_COUNT=$(ip netns exec fw conntrack -L 2>/dev/null | wc -l || echo "0")
echo "  当前活跃连接数: $CONN_COUNT"
if [ "$CONN_COUNT" -gt 0 ]; then
  echo "  最近连接:"
  ip netns exec fw conntrack -L 2>/dev/null | head -10
fi

echo ""
info "防御4: 检查 WireGuard 隧道状态"
ip netns exec fw wg show

# ============================================================
# 边界测试与改进
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  边界测试与安全改进${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "改进1: 添加连接数限制（已在 firewall.sh 中配置）"
echo "  规则: -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT"
ip netns exec fw iptables -L FORWARD -n -v | grep connlimit || echo "  (规则未找到)"

echo ""
info "改进2: 建议添加 rp_filter（反向路径过滤）"
echo "  当前 rp_filter 设置:"
ip netns exec fw sysctl net.ipv4.conf.all.rp_filter 2>/dev/null || echo "  (无法读取)"
echo "  建议: sysctl -w net.ipv4.conf.all.rp_filter=1"

echo ""
info "改进3: 建议添加 SYN flood 防护"
echo "  规则: -m limit --limit 10/s --limit-burst 20 -j ACCEPT (SYN包限速)"

echo ""
info "攻防演练完成"
