#!/bin/bash
# ============================================================
# test.sh — 防火墙与VPN技术期末大作业：完整测试脚本
# 功能：启动测试服务，执行全部测试矩阵，输出结果
# 运行环境：先执行 setup.sh, firewall.sh, vpn-setup.sh 后运行
# ============================================================

# 不用 set -e，因为测试本身会故意触发失败
# set -e 会让"预期失败"的测试直接终止脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

PASS_STR="${GREEN}PASS${NC}"
FAIL_STR="${RED}FAIL${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} 请使用 sudo 运行此脚本"
  exit 1
fi

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ---- 测试函数 ----
run_test() {
  local desc="$1"
  local expect="$2"  # pass 或 fail
  shift 2
  local cmd="$@"

  TOTAL=$((TOTAL + 1))
  echo ""
  echo -e "${BLUE}[测试 ${TOTAL}]${NC} ${desc}"
  echo -e "${YELLOW}命令:${NC} ${cmd}"

  if eval "$cmd" >/dev/null 2>&1; then
    if [ "$expect" = "pass" ]; then
      echo -e "结果: ${PASS_STR}"
      PASS=$((PASS + 1))
    else
      echo -e "结果: ${FAIL_STR} (预期失败但成功了)"
      FAIL=$((FAIL + 1))
    fi
  else
    if [ "$expect" = "fail" ]; then
      echo -e "结果: ${PASS_STR} (预期拒绝，正确)"
      PASS=$((PASS + 1))
    else
      echo -e "结果: ${FAIL_STR} (预期成功但失败了)"
      FAIL=$((FAIL + 1))
      # 对预期成功但失败的测试，显示简要错误信息以便诊断
      echo -e "${YELLOW}详细输出（前5行）:${NC}"
      eval "$cmd" 2>&1 | head -5 || true
    fi
  fi
}

# ============================================================
# 0. 清理残留进程 + 启动测试服务
# ============================================================
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第0步：清理残留进程并启动测试服务${NC}"
echo -e "${BLUE}============================================================${NC}"

# 先 kill 各 namespace 里残留的 python3 http.server 和 curl 进程
info "清理残留的 http.server 进程..."
for ns in dmz office internet; do
  ip netns exec "$ns" pkill -f "python3 -m http.server" 2>/dev/null || true
done
# 等 1 秒让端口释放
sleep 1

# 在 dmz 上启动 Web 服务 (8080)
info "在 dmz 启动 Web 服务 (端口8080)..."
ip netns exec dmz python3 -m http.server 8080 --bind 10.40.0.2 &
DMZ_WEB_PID=$!
sleep 1
# 验证服务是否启动
if ip netns exec dmz ss -tlnp 2>/dev/null | grep -q 8080; then
  info "dmz:8080 服务已启动 (PID $DMZ_WEB_PID)"
else
  warn "dmz:8080 可能未成功启动，重试..."
  ip netns exec dmz python3 -m http.server 8080 --bind 0.0.0.0 &
  DMZ_WEB_PID=$!
  sleep 1
fi

info "在 dmz 启动模拟SSH服务 (端口22)..."
ip netns exec dmz python3 -m http.server 22 --bind 10.40.0.2 &
DMZ_SSH_PID=$!
sleep 1

info "在 office 启动 Web 服务 (端口8000)..."
ip netns exec office python3 -m http.server 8000 --bind 10.20.0.2 &
OFFICE_WEB_PID=$!
sleep 1

info "在 internet 启动 Web 服务 (端口80)..."
ip netns exec internet python3 -m http.server 80 --bind 203.0.113.10 &
INET_WEB_PID=$!
sleep 1

info "测试服务已启动"
info "dmz Web PID: $DMZ_WEB_PID, dmz SSH PID: $DMZ_SSH_PID"
info "office Web PID: $OFFICE_WEB_PID, internet Web PID: $INET_WEB_PID"

# ============================================================
# 第一部分：基础连通性测试
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第一部分：基础连通性测试${NC}"
echo -e "${BLUE}============================================================${NC}"

run_test "office -> fw (10.20.0.1)" pass \
  "ip netns exec office ping -c 2 -W 2 10.20.0.1"

run_test "guest -> fw (10.30.0.1)" pass \
  "ip netns exec guest ping -c 2 -W 2 10.30.0.1"

run_test "dmz -> fw (10.40.0.1)" pass \
  "ip netns exec dmz ping -c 2 -W 2 10.40.0.1"

run_test "internet -> fw (203.0.113.1)" pass \
  "ip netns exec internet ping -c 2 -W 2 203.0.113.1"

# ============================================================
# 第二部分：防火墙策略测试
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第二部分：防火墙策略测试${NC}"
echo -e "${BLUE}============================================================${NC}"

run_test "office -> dmz:8080 (应成功)" pass \
  "ip netns exec office curl --max-time 5 -s -o /dev/null http://10.40.0.2:8080/"

run_test "office -> dmz:22 (应拒绝)" fail \
  "ip netns exec office curl --max-time 3 -s -o /dev/null http://10.40.0.2:22/"

run_test "office -> internet:80 (应成功，NAT)" pass \
  "ip netns exec office curl --max-time 5 -s -o /dev/null http://203.0.113.10:80/"

run_test "guest -> office:8000 (应拒绝)" fail \
  "ip netns exec guest curl --max-time 3 -s -o /dev/null http://10.20.0.2:8000/"

run_test "guest -> dmz:8080 (应拒绝)" fail \
  "ip netns exec guest curl --max-time 3 -s -o /dev/null http://10.40.0.2:8080/"

run_test "guest -> internet:80 (应成功，NAT)" pass \
  "ip netns exec guest curl --max-time 5 -s -o /dev/null http://203.0.113.10:80/"

run_test "internet -> fw:8080 (DNAT到dmz，应成功)" pass \
  "ip netns exec internet curl --max-time 5 -s -o /dev/null http://203.0.113.1:8080/"

run_test "internet -> office:8000 (应拒绝)" fail \
  "ip netns exec internet curl --max-time 3 -s -o /dev/null http://10.20.0.2:8000/"

run_test "internet -> dmz:8080 直连 (应拒绝)" fail \
  "ip netns exec internet curl --max-time 3 -s -o /dev/null http://10.40.0.2:8080/"

# ============================================================
# 第三部分：VPN 测试
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第三部分：VPN 远程接入测试${NC}"
echo -e "${BLUE}============================================================${NC}"

run_test "remote -> fw VPN隧道 ping (10.10.10.1)" pass \
  "ip netns exec remote ping -c 2 -W 5 10.10.10.1"

run_test "remote -> office:8000 (VPN，应成功)" pass \
  "ip netns exec remote curl --max-time 5 -s -o /dev/null http://10.20.0.2:8000/"

run_test "remote -> dmz:8080 (VPN，应成功)" pass \
  "ip netns exec remote curl --max-time 5 -s -o /dev/null http://10.40.0.2:8080/"

run_test "remote -> dmz:22 (VPN，应拒绝)" fail \
  "ip netns exec remote curl --max-time 3 -s -o /dev/null http://10.40.0.2:22/"

run_test "remote -> guest (VPN，应拒绝)" fail \
  "ip netns exec remote ping -c 2 -W 3 10.30.0.2"

# VPN 测试后的专用诊断输出
if ip netns exec remote ping -c 1 -W 2 10.10.10.1 >/dev/null 2>&1; then
  info "VPN 隧道 ping 10.10.10.1 成功"
else
  warn "VPN 隧道 ping 10.10.10.1 失败，诊断信息如下:"
  echo "--- remote wg show ---"
  ip netns exec remote wg show 2>/dev/null || echo "(无法获取)"
  echo "--- fw wg show ---"
  ip netns exec fw wg show 2>/dev/null || echo "(无法获取)"
  echo "--- remote 路由表 ---"
  ip netns exec remote ip route 2>/dev/null || echo "(无法获取)"
  echo "--- fw 路由表(192.0.2.0/24) ---"
  ip netns exec fw ip route show 192.0.2.0/24 2>/dev/null || echo "(无此路由)"
fi

# ============================================================
# 第四部分：安全审计 - 日志检查
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第四部分：安全审计 - 日志统计${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "触发违规场景以产生日志..."

# 触发多次违规
for i in $(seq 1 3); do
  ip netns exec guest curl --max-time 1 -s -o /dev/null http://10.20.0.2:8000/ 2>/dev/null || true
  ip netns exec guest curl --max-time 1 -s -o /dev/null http://10.40.0.2:8080/ 2>/dev/null || true
  ip netns exec remote curl --max-time 1 -s -o /dev/null http://10.40.0.2:22/ 2>/dev/null || true
  ip netns exec internet curl --max-time 1 -s -o /dev/null http://10.20.0.2:8000/ 2>/dev/null || true
done

sleep 1

echo ""
info "iptables FORWARD 链规则计数器:"
ip netns exec fw iptables -L FORWARD -n -v --line-numbers

echo ""
info "iptables INPUT 链规则计数器:"
ip netns exec fw iptables -L INPUT -n -v --line-numbers

echo ""
info "iptables NAT 表规则:"
ip netns exec fw iptables -t nat -L -n -v --line-numbers

# 安全审计日志读取函数（兼容 WSL2：优先 journalctl，fallback dmesg）
read_audit_logs() {
  if command -v journalctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
    journalctl -k --no-pager 2>/dev/null
  else
    dmesg 2>/dev/null
  fi
}

echo ""
info "内核日志中的安全事件统计:"

for prefix in "GUEST-TO-OFFICE" "GUEST-TO-DMZ" "VPN-TO-DMZ-SSH" "INET-TO-OFFICE" "VPN-DENY" "OFFICE-TO-DMZ-SSH"; do
  COUNT=$(read_audit_logs | grep "$prefix" | wc -l)
  echo -e "  ${YELLOW}${prefix}${NC}: ${COUNT} 条"
done

echo ""
info "最近10条安全日志:"
read_audit_logs | grep -E "GUEST-TO-|VPN-|INET-TO-|OFFICE-TO-" | tail -10 || echo "  (无日志或日志读取不可用)"

# ============================================================
# 第五部分：WireGuard 隧道状态
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  第五部分：WireGuard 隧道状态${NC}"
echo -e "${BLUE}============================================================${NC}"

echo ""
info "fw 端 wg show:"
ip netns exec fw wg show 2>/dev/null || warn "WireGuard 未运行或 wg0 不存在"

echo ""
info "remote 端 wg show:"
ip netns exec remote wg show 2>/dev/null || warn "WireGuard 未运行或 wg0 不存在"

# ============================================================
# 测试结果汇总
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  测试结果汇总${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "总计: ${TOTAL}  通过: ${GREEN}${PASS}${NC}  失败: ${RED}${FAIL}${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}  所有测试通过!${NC}"
  echo -e "${GREEN}========================================${NC}"
else
  echo -e "${RED}========================================${NC}"
  echo -e "${RED}  有 ${FAIL} 个测试失败，请检查规则配置${NC}"
  echo -e "${RED}========================================${NC}"
fi

# ============================================================
# 清理测试服务
# ============================================================
echo ""
info "清理测试服务..."
kill $DMZ_WEB_PID 2>/dev/null || true
kill $DMZ_SSH_PID 2>/dev/null || true
kill $OFFICE_WEB_PID 2>/dev/null || true
kill $INET_WEB_PID 2>/dev/null || true
# 也 kill 可能残留的其他 http.server 进程
for ns in dmz office internet; do
  ip netns exec "$ns" pkill -f "python3 -m http.server" 2>/dev/null || true
done
info "测试服务已清理"

echo ""
info "全部测试完成。请截图保存各步骤输出。"