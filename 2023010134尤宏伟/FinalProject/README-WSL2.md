# WSL2 Ubuntu 26.04 运行指南

本指南专门针对 WSL2 + Ubuntu 26.04 LTS 环境编写。

## 环境信息确认

你的环境应该是：

```
NAME="Ubuntu"
VERSION_ID="26.04"
内核: 6.18.x-microsoft-standard-WSL2
```

## 第一步：复制项目到 WSL2

在 WSL2 终端中执行：

```bash
# 假设 Windows 文件在 D:\workbuddy生成\2026-07-02-08-13-00\FinalProject
mkdir -p ~/FinalProject
cp -r /mnt/d/workbuddy生成/2026-07-02-08-13-00/FinalProject/* ~/FinalProject/
cd ~/FinalProject
chmod +x *.sh
```

## 第二步：安装依赖

```bash
sudo bash wsl2-install.sh
```

这个脚本会自动处理 Ubuntu 26.04 的包名差异：
- `wireguard-tools` 或 `wireguard` 或 `wireguard-go`
- `conntrack` 或 `conntrack-tools`

## 第三步：一键运行完整实验

```bash
sudo bash run-all.sh
```

这个脚本会按顺序执行：
1. 检查依赖
2. 安装缺失依赖
3. 运行 setup.sh（搭建网络）
4. 运行 firewall.sh（配置防火墙）
5. 运行 vpn-setup.sh（配置 WireGuard）
6. 运行 test.sh（完整测试）

## 第四步：截图

实验完成后，按照 `screenshots/截图清单.md` 截取 20 张截图。

WSL2 截图推荐方式：
- 按 `Win + Shift + S` 截取 WSL2 终端窗口
- 或安装 `gnome-screenshot`：
  ```bash
  sudo apt install gnome-screenshot
  gnome-screenshot -f screenshot.png
  ```

## 第五步：清理环境

```bash
sudo bash cleanup.sh
```

## 常见问题

### 1. `journalctl -k` 没有输出

WSL2 默认可能无法读取内核日志。test.sh 已自动 fallback 到 `dmesg`。

如果 `dmesg` 也没有相关日志，可以检查：
```bash
sudo dmesg | grep "GUEST-TO-"
```

### 2. WireGuard 隧道起不来

WSL2 的微软定制内核可能没有编译 wireguard 模块。wsl2-install.sh 会安装 `wireguard-go` 作为 fallback，vpn-setup.sh 会自动检测并使用它。

### 3. `iptables` 规则报错

Ubuntu 26.04 的 iptables 默认可能是 nftables 后端。如果某些模块不可用，尝试：
```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
```

### 4. namespace 创建失败

WSL2 需要版本 2。确认：
```bash
wsl.exe --list --verbose
```

如果不是版本 2，在 PowerShell 中执行：
```powershell
wsl --set-version Ubuntu 2
```

## 手动分步运行（如果一键脚本失败）

```bash
sudo bash setup.sh
sudo bash firewall.sh
sudo bash vpn-setup.sh
sudo bash test.sh
sudo bash audit.sh
sudo bash attack.sh
```
