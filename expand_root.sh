#!/bin/bash
# 交互式根分区扩容脚本（支持 ext4 / xfs）
# 需要 root 权限执行

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查是否为 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：此脚本需要 root 权限运行。${NC}"
   exit 1
fi

# 获取根分区设备（如 /dev/sda1）
ROOT_DEV=$(df / | awk 'NR==2 {print $1}')
if [[ -z "$ROOT_DEV" ]]; then
    echo -e "${RED}错误：无法获取根分区设备。${NC}"
    exit 1
fi

# 获取磁盘设备名（如 /dev/sda）和分区号
DISK=$(echo "$ROOT_DEV" | sed -E 's/[0-9]+$//' | sed 's/p$//')   # 去除分区号，保留磁盘设备
PART_NUM=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')

if [[ -z "$DISK" || -z "$PART_NUM" ]]; then
    echo -e "${RED}错误：无法解析磁盘设备或分区号。${NC}"
    exit 1
fi

# 获取磁盘总容量（字节）
DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DISK" | head -1)
# 获取当前分区起始扇区和大小（扇区数）
PART_START=$(parted "$DISK" unit s print | grep -E "^ ${PART_NUM} " | awk '{print $2}' | sed 's/s$//')
PART_END=$(parted "$DISK" unit s print | grep -E "^ ${PART_NUM} " | awk '{print $3}' | sed 's/s$//')
DISK_END=$(parted "$DISK" unit s print | grep -E "^Disk $DISK:" | awk '{print $3}' | sed 's/s$//')

if [[ -z "$PART_START" || -z "$PART_END" || -z "$DISK_END" ]]; then
    echo -e "${RED}错误：无法获取分区表信息。请确保已安装 parted。${NC}"
    exit 1
fi

# 计算当前分区大小（扇区数）和可用扇区数
CURRENT_SECTORS=$((PART_END - PART_START + 1))
MAX_SECTORS=$((DISK_END - PART_START + 1))
FREE_SECTORS=$((MAX_SECTORS - CURRENT_SECTORS))

# 转换为 GB（1 扇区 = 512 字节，但实际可能不同，我们以字节为准）
SECTOR_SIZE=$(parted "$DISK" unit s print | grep "Sector size" | awk '{print $3}')
if [[ -z "$SECTOR_SIZE" ]]; then
    SECTOR_SIZE=512  # 默认
fi

CURRENT_GB=$(echo "scale=2; $CURRENT_SECTORS * $SECTOR_SIZE / 1024^3" | bc)
MAX_GB=$(echo "scale=2; $MAX_SECTORS * $SECTOR_SIZE / 1024^3" | bc)
FREE_GB=$(echo "scale=2; $FREE_SECTORS * $SECTOR_SIZE / 1024^3" | bc)

echo -e "${GREEN}=== 根分区扩容工具 ===${NC}"
echo "根分区设备: $ROOT_DEV"
echo "磁盘: $DISK"
echo "分区号: $PART_NUM"
echo -e "当前分区大小: ${YELLOW}${CURRENT_GB} GB${NC}"
echo -e "磁盘总大小:   ${YELLOW}${MAX_GB} GB${NC}"
echo -e "可扩容空间:   ${YELLOW}${FREE_GB} GB${NC}"

# 检查是否为最后一个分区（即分区结束位置是否在磁盘末尾之前）
# 如果分区后还有未分配空间，则允许扩容
if [[ $PART_END -ge $DISK_END ]]; then
    echo -e "${RED}错误：当前分区已占满整个磁盘，无可扩容空间。${NC}"
    exit 1
fi

# 检查是否安装了必要工具
if ! command -v growpart &> /dev/null; then
    echo -e "${YELLOW}growpart 未安装，正在尝试安装 cloud-guest-utils...${NC}"
    apt update && apt install -y cloud-guest-utils || { echo -e "${RED}安装失败，请手动安装 growpart。${NC}"; exit 1; }
fi

FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
if [[ "$FS_TYPE" == "ext4" ]]; then
    if ! command -v resize2fs &> /dev/null; then
        echo -e "${YELLOW}resize2fs 未安装，正在安装 e2fsprogs...${NC}"
        apt install -y e2fsprogs
    fi
elif [[ "$FS_TYPE" == "xfs" ]]; then
    if ! command -v xfs_growfs &> /dev/null; then
        echo -e "${YELLOW}xfs_growfs 未安装，正在安装 xfsprogs...${NC}"
        apt install -y xfsprogs
    fi
else
    echo -e "${RED}不支持的文件系统类型: $FS_TYPE${NC}"
    exit 1
fi

# 交互输入扩容大小
echo ""
read -p "请输入要扩容的大小（单位 G，例如 10，或直接回车使用全部可用空间）: " input

if [[ -z "$input" ]]; then
    ADD_GB=$FREE_GB
    echo "将使用全部可用空间: ${ADD_GB} GB"
else
    # 检查输入是否为数字
    if ! [[ "$input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "${RED}错误：请输入有效数字（如 5 或 10.5）。${NC}"
        exit 1
    fi
    # 比较不能超过可用空间
    if (( $(echo "$input > $FREE_GB" | bc -l) )); then
        echo -e "${RED}错误：输入值超过可用空间 (${FREE_GB} GB)。${NC}"
        exit 1
    fi
    ADD_GB=$input
fi

# 计算要增加的扇区数
ADD_SECTORS=$(echo "$ADD_GB * 1024^3 / $SECTOR_SIZE" | bc)
NEW_TOTAL_SECTORS=$((CURRENT_SECTORS + ADD_SECTORS))
NEW_END=$((PART_START + NEW_TOTAL_SECTORS - 1))

# 确认操作
echo ""
echo -e "${YELLOW}即将执行以下操作：${NC}"
echo "分区 $PART_NUM 将从扇区 ${PART_START} 扩展到扇区 ${NEW_END}"
echo "新分区大小约为: $(echo "scale=2; $NEW_TOTAL_SECTORS * $SECTOR_SIZE / 1024^3" | bc) GB"
read -p "是否继续？(y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    exit 0
fi

# 执行扩容
echo "正在扩展分区..."
growpart "$DISK" "$PART_NUM" "$NEW_END" || { echo -e "${RED}分区扩展失败，请检查日志。${NC}"; exit 1; }

# 扩展文件系统
echo "正在扩展文件系统..."
if [[ "$FS_TYPE" == "ext4" ]]; then
    resize2fs "$ROOT_DEV" || { echo -e "${RED}文件系统扩展失败。${NC}"; exit 1; }
elif [[ "$FS_TYPE" == "xfs" ]]; then
    xfs_growfs / || { echo -e "${RED}文件系统扩展失败。${NC}"; exit 1; }
fi

echo -e "${GREEN}扩容成功！${NC}"
df -h /
