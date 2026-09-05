#!/bin/bash

# =============================================
# Proxmox VE - Debian12 Cloud 镜像交互式创建脚本
# 针对你的常用配置优化（已取消 serial0 + vga serial0）
# 镜像路径: /root/PVE-ISO/Debian12-Cloud.qcow2
# =============================================

IMAGE="/root/PVE-ISO/Debian12-Cloud.qcow2"
STORAGE="local-lvm"
BRIDGE="vmbr1"                # 默认使用你的 vmbr1

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 检查镜像
if [ ! -f "$IMAGE" ]; then
    echo -e "${RED}错误：镜像文件 $IMAGE 不存在！${NC}"
    exit 1
fi

clear
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Debian 12 Cloud 虚拟机创建脚本${NC}"
echo -e "${GREEN}  （已按你常用配置优化）${NC}"
echo -e "${GREEN}======================================${NC}"
echo

# 1. 虚拟机 ID
while true; do
    read -p "请输入虚拟机 ID (例如 100): " VMID
    if [[ "$VMID" =~ ^[0-9]+$ ]] && [ "$VMID" -ge 100 ]; then
        if qm status $VMID &>/dev/null; then
            echo -e "${RED}错误：虚拟机 ID $VMID 已存在，请换一个！${NC}"
        else
            break
        fi
    else
        echo -e "${YELLOW}请输入有效的数字 ID（建议 ≥100）${NC}"
    fi
done

# 2. 虚拟机名称
read -p "请输入虚拟机名称 [默认: Debian12]: " VMNAME
VMNAME=${VMNAME:-Debian12}

# 3. 内存大小
while true; do
    read -p "请输入内存大小 (MB) [默认: 8192]: " MEMORY
    MEMORY=${MEMORY:-8192}
    if [[ "$MEMORY" =~ ^[0-9]+$ ]] && [ "$MEMORY" -ge 512 ]; then
        break
    else
        echo -e "${YELLOW}请输入有效的内存大小（至少 512）${NC}"
    fi
done

# 4. 磁盘大小
while true; do
    read -p "请输入磁盘大小 (GB) [默认: 50]: " DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-50}
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] && [ "$DISK_SIZE" -ge 5 ]; then
        break
    else
        echo -e "${YELLOW}请输入有效的磁盘大小（至少 5）${NC}"
    fi
done

# 5. CPU 核心数
while true; do
    read -p "请输入 CPU 核心数 [默认: 4]: " CORES
    CORES=${CORES:-4}
    if [[ "$CORES" =~ ^[0-9]+$ ]] && [ "$CORES" -ge 1 ]; then
        break
    else
        echo -e "${YELLOW}请输入有效的 CPU 核心数（至少 1）${NC}"
    fi
done

# 可选：是否添加 Cloud-Init 驱动
echo
read -p "是否添加 Cloud-Init 驱动？(y/n) [默认: n]: " ADD_CI
ADD_CI=${ADD_CI:-n}

echo
echo -e "${YELLOW}--------------------------------------${NC}"
echo "即将创建虚拟机，参数如下："
echo "  VM ID       : $VMID"
echo "  名称        : $VMNAME"
echo "  内存        : ${MEMORY} MB"
echo "  磁盘        : ${DISK_SIZE} GB"
echo "  CPU         : $CORES 核 (host)"
echo "  网桥        : $BRIDGE"
echo "  存储        : $STORAGE"
echo "  Cloud-Init  : $ADD_CI"
echo -e "${YELLOW}--------------------------------------${NC}"
echo

read -p "确认创建？(y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消创建"
    exit 0
fi

echo
echo -e "${GREEN}开始创建虚拟机...${NC}"

# 1. 创建虚拟机（已取消 serial0 + vga serial0）
qm create $VMID \
  --name "$VMNAME" \
  --memory $MEMORY \
  --cores $CORES \
  --cpu host \
  --net0 virtio,bridge=$BRIDGE \
  --scsihw virtio-scsi-pci \
  --ostype l26 \
  --agent 1 \
  --onboot 0

if [ $? -ne 0 ]; then
    echo -e "${RED}创建虚拟机失败！${NC}"
    exit 1
fi

# 2. 导入磁盘
echo "正在导入磁盘镜像（请稍候）..."
qm importdisk $VMID "$IMAGE" $STORAGE

if [ $? -ne 0 ]; then
    echo -e "${RED}导入磁盘失败！${NC}"
    qm destroy $VMID --purge
    exit 1
fi

# 3. 挂载磁盘
qm set $VMID --scsi0 ${STORAGE}:vm-${VMID}-disk-0,discard=on

# 4. 调整磁盘大小
echo "正在调整磁盘大小到 ${DISK_SIZE}G..."
qm resize $VMID scsi0 ${DISK_SIZE}G

# 5. 设置启动顺序
qm set $VMID --boot order=scsi0

# 6. 可选添加 Cloud-Init
if [[ "$ADD_CI" =~ ^[Yy]$ ]]; then
    echo "正在添加 Cloud-Init 驱动..."
    qm set $VMID --ide2 ${STORAGE}:cloudinit
    qm set $VMID --ipconfig0 ip=dhcp
    # 如果你有固定的 userdata，可以取消下面注释并修改路径
    # qm set $VMID --cicustom "user=local:snippets/debian12-userdata.yaml"
fi

echo
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  虚拟机创建成功！${NC}"
echo -e "${GREEN}======================================${NC}"
echo "VM ID     : $VMID"
echo "名称      : $VMNAME"
echo "启动命令  : qm start $VMID"
echo
echo "登录信息："
echo "  root 密码 : QAZxsw412500.."
echo "  普通用户  : Yezhu / Z32GADKE"
echo -e "${GREEN}======================================${NC}"
