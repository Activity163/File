#!/bin/bash
#
# =============================================
# Proxmox VE - Debian 13 (trixie) 虚拟机创建脚本
# 适配镜像: /root/PVE-ISO/Debian13-PVE-50G.qcow2
#
# 该镜像的特性（均为实测结论，决定了本脚本的做法）：
#   - 虚拟磁盘 50G，qcow2 压缩格式；PVE 无法把磁盘改小
#   - 已固化: systemd-networkd DHCP 自动获取 IPv4
#   - 已固化: root 通过 SSH 密码登录 (PermitRootLogin yes / PasswordAuthentication yes)
#   - 已固化: root 密码，systemd-firstboot 已屏蔽，开机无首次启动向导
#   - 未安装: cloud-init          -> 不需要也不能用 cloud-init 驱动
#   - 未安装: qemu-guest-agent    -> --agent 1 暂时无效，进系统后装一下即可
#   - 同时支持 UEFI(OVMF) 与 BIOS(SeaBIOS) 引导
#
#   分区布局（磁盘 50G，无剩余空间）：
#     p14  2048-8191       3.0 MiB  EF02  bios_grub（给 SeaBIOS 用）
#     p15  8192-262143   124.0 MiB  EF00  ESP（给 OVMF 用）
#     p1   262144-末尾    49.9 GiB  8304  root ext4
#   => p14/p15 在磁盘【开头】，root 在【末尾】，所以扩容后新空间紧跟在 p1 之后，
#      growpart 可以正常把 p1 扩到磁盘末尾。
#
#   注意：镜像里【没有任何分区工具】（growpart / sfdisk / parted / fdisk 全都没有），
#        想把磁盘扩到 50G 以上，必须在客户机里先装一个（见脚本结尾第 3 条）。
# =============================================

set -u

IMAGE="${IMAGE:-/root/PVE-ISO/Debian13-PVE-50G.qcow2}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr1}"

IMAGE_DISK_GB=50                            # 镜像内虚拟磁盘大小（硬下限）
ROOT_PASS='FDsdHgufNN0F71ioJ7dG'
DEFAULT_NAME="Debian13"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- 前置检查 ----------
if ! command -v qm >/dev/null 2>&1; then
    echo -e "${RED}错误：未找到 qm 命令，请在 Proxmox VE 宿主机上运行本脚本${NC}"
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo -e "${RED}错误：镜像文件不存在: $IMAGE${NC}"
    echo "请先把 debian-13-pve-50G.qcow2 放到该路径，或用环境变量指定："
    echo "  IMAGE=/path/to/debian-13-pve-50G.qcow2 bash $0"
    exit 1
fi

# 从镜像里读出真实虚拟磁盘大小，比写死 50 更稳（读不到就沿用上面的默认值）
if command -v qemu-img >/dev/null 2>&1; then
    _bytes=$(qemu-img info --output=json "$IMAGE" 2>/dev/null \
             | grep -oE '"virtual-size":[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
    if [ -n "${_bytes:-}" ] && [ "$_bytes" -gt 0 ] 2>/dev/null; then
        IMAGE_DISK_GB=$(( (_bytes + 1073741823) / 1073741824 ))
    fi
fi

clear
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Debian 13 (trixie) 虚拟机创建脚本${NC}"
echo -e "${GREEN}  镜像: $IMAGE${NC}"
echo -e "${GREEN}======================================${NC}"
echo

# ---------- 1. 虚拟机 ID ----------
while true; do
    read -p "请输入虚拟机 ID (例如 100): " VMID
    if [[ "$VMID" =~ ^[0-9]+$ ]] && [ "$VMID" -ge 100 ]; then
        if qm status "$VMID" &>/dev/null; then
            echo -e "${RED}错误：虚拟机 ID $VMID 已存在，请换一个！${NC}"
        else
            break
        fi
    else
        echo -e "${YELLOW}请输入有效的数字 ID（建议 ≥100）${NC}"
    fi
done

# ---------- 2. 虚拟机名称 ----------
read -p "请输入虚拟机名称 [默认: $DEFAULT_NAME]: " VMNAME
VMNAME=${VMNAME:-$DEFAULT_NAME}

# ---------- 3. 内存 ----------
while true; do
    read -p "请输入内存大小 (MB) [默认: 8192]: " MEMORY
    MEMORY=${MEMORY:-8192}
    if [[ "$MEMORY" =~ ^[0-9]+$ ]] && [ "$MEMORY" -ge 512 ]; then break; fi
    echo -e "${YELLOW}请输入有效的内存大小（至少 512）${NC}"
done

# ---------- 4. 磁盘大小 ----------
echo
echo -e "${CYAN}注意：镜像自带虚拟磁盘已是 ${IMAGE_DISK_GB}G，PVE 不支持把磁盘改小。${NC}"
while true; do
    read -p "请输入磁盘大小 (GB) [默认: ${IMAGE_DISK_GB}]: " DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-$IMAGE_DISK_GB}
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] && [ "$DISK_SIZE" -ge "$IMAGE_DISK_GB" ]; then break; fi
    echo -e "${YELLOW}请输入 ≥ ${IMAGE_DISK_GB} 的整数（镜像本身已是 ${IMAGE_DISK_GB}G，无法缩小）${NC}"
done

# ---------- 5. CPU ----------
while true; do
    read -p "请输入 CPU 核心数 [默认: 4]: " CORES
    CORES=${CORES:-4}
    if [[ "$CORES" =~ ^[0-9]+$ ]] && [ "$CORES" -ge 1 ]; then break; fi
    echo -e "${YELLOW}请输入有效的 CPU 核心数（至少 1）${NC}"
done

# ---------- 6. 固件 ----------
echo
echo -e "${CYAN}固件：UEFI(OVMF) 更现代，镜像含完整 ESP 分区（shim + BOOTX64.EFI）；"
echo -e "      BIOS(SeaBIOS) 更简单，不额外占用一个 efidisk 卷。两者均已实测可引导。${NC}"
while true; do
    read -p "使用哪种固件？(1=UEFI  2=BIOS) [默认: 1]: " FW
    FW=${FW:-1}
    case "$FW" in
        1|2) break ;;
        *) echo -e "${YELLOW}请输入 1 或 2${NC}" ;;
    esac
done

if [ "$FW" = "1" ]; then
    FIRMWARE_DESC="UEFI (OVMF + q35)"
    FW_ARGS=(--bios ovmf --machine q35 --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0")
else
    FIRMWARE_DESC="BIOS (SeaBIOS + i440fx)"
    FW_ARGS=(--bios seabios --machine pc)
fi

# ---------- 7. 串口控制台 ----------
read -p "启用串口控制台 serial0（可用 qm terminal 登录）？(y/n) [默认: n]: " ADD_SERIAL
ADD_SERIAL=${ADD_SERIAL:-n}
if [[ "$ADD_SERIAL" =~ ^[Yy]$ ]]; then
    SERIAL_DESC="启用"
    SERIAL_ARGS=(--serial0 socket)
else
    SERIAL_DESC="不启用（用 Web UI 的 noVNC 控制台）"
    SERIAL_ARGS=()
fi

# ---------- 确认 ----------
echo
echo -e "${YELLOW}--------------------------------------${NC}"
echo "即将创建虚拟机，参数如下："
echo "  VM ID       : $VMID"
echo "  名称        : $VMNAME"
echo "  内存        : ${MEMORY} MB"
echo "  磁盘        : ${DISK_SIZE} GB（镜像原始 ${IMAGE_DISK_GB}G）"
echo "  CPU         : $CORES 核 (host)"
echo "  固件        : $FIRMWARE_DESC"
echo "  网桥        : $BRIDGE"
echo "  存储        : $STORAGE"
echo "  串口控制台  : $SERIAL_DESC"
echo "  Cloud-Init  : 不使用（镜像未安装 cloud-init，配置已固化在镜像内）"
echo -e "${YELLOW}--------------------------------------${NC}"
echo

read -p "确认创建？(y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消创建"
    exit 0
fi

echo
echo -e "${GREEN}开始创建虚拟机...${NC}"

# ---------- 1. 创建虚拟机 ----------
if ! qm create "$VMID" \
    --name "$VMNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio,bridge="$BRIDGE" \
    --scsihw virtio-scsi-pci \
    --ostype l26 \
    --agent 1 \
    --onboot 0 \
    "${FW_ARGS[@]}" \
    "${SERIAL_ARGS[@]}"; then
    echo -e "${RED}创建虚拟机失败！${NC}"
    exit 1
fi

# ---------- 2. 导入磁盘 ----------
echo "正在导入磁盘镜像（请稍候，50G 镜像需要一点时间）..."
if ! qm importdisk "$VMID" "$IMAGE" "$STORAGE"; then
    echo -e "${RED}导入磁盘失败！${NC}"
    qm destroy "$VMID" --purge
    exit 1
fi

# ---------- 3. 挂载磁盘 ----------
# 关键：不能写死 vm-${VMID}-disk-0。
# UEFI 模式下 efidisk0 会先占用 disk-0，导入的磁盘会变成 disk-1。
# 因此从 qm config 里读未使用磁盘（unusedN）的实际卷名，最稳妥。
UNUSED_KEY=$(qm config "$VMID" | grep -oE '^unused[0-9]+' | head -1)
UNUSED_VAL=$(qm config "$VMID" | awk -F': ' -v k="$UNUSED_KEY" '$1 == k {print $2}')

if [ -z "$UNUSED_KEY" ] || [ -z "$UNUSED_VAL" ]; then
    echo -e "${RED}错误：未能在 qm config 中找到导入后的未使用磁盘${NC}"
    qm config "$VMID"
    qm destroy "$VMID" --purge
    exit 1
fi

echo "导入的磁盘卷: $UNUSED_KEY = $UNUSED_VAL"
qm set "$VMID" --scsi0 "${UNUSED_VAL},discard=on"
# 若 PVE 未自动清掉 unusedN，这里兜底删除（失败不影响结果）
qm set "$VMID" --delete "$UNUSED_KEY" 2>/dev/null || true

# ---------- 4. 调整磁盘大小 ----------
if [ "$DISK_SIZE" -gt "$IMAGE_DISK_GB" ]; then
    echo "正在把磁盘从 ${IMAGE_DISK_GB}G 扩展到 ${DISK_SIZE}G ..."
    qm resize "$VMID" scsi0 "${DISK_SIZE}G"
    RESIZE_NEEDED=1
else
    echo "磁盘保持 ${IMAGE_DISK_GB}G（等于镜像原始大小，无需调整）"
    RESIZE_NEEDED=0
fi

# ---------- 5. 设置启动顺序 ----------
qm set "$VMID" --boot order=scsi0

echo
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  虚拟机创建成功！${NC}"
echo -e "${GREEN}======================================${NC}"
echo "VM ID     : $VMID"
echo "名称      : $VMNAME"
echo "固件      : $FIRMWARE_DESC"
echo "启动命令  : qm start $VMID"
[ "$SERIAL_DESC" = "启用" ] && echo "串口登录  : qm terminal $VMID"
echo
echo -e "${YELLOW}登录信息：${NC}"
echo "  用户      : root"
echo "  密码      : $ROOT_PASS"
echo "  普通用户  : 无（镜像只有 root）"
echo
echo -e "${YELLOW}--------------------------------------${NC}"
echo -e "${YELLOW}开机后建议做的事${NC}"
echo -e "${YELLOW}--------------------------------------${NC}"
echo "1) 装上 QEMU Guest Agent（镜像没预装，装上后 PVE 才能优雅关机/显示 IP/执行 qm guest exec）："
echo "     apt-get update && apt-get install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent"
echo
echo "2) 重置实例标识（重要：镜像为了不依赖首次启动向导，把 machine-id 和 SSH 主机密钥"
echo "   烧死在镜像里了。用同一个镜像创建多台虚拟机时，它们会完全一样，建议每台都执行）："
echo "     rm -f /etc/machine-id /var/lib/dbus/machine-id"
echo "     systemd-machine-id-setup"
echo "     rm -f /etc/ssh/ssh_host_*"
echo "     ssh-keygen -A"
echo "     systemctl restart ssh"
echo
if [ "${RESIZE_NEEDED:-0}" = "1" ]; then
    echo "3) 扩展根分区（磁盘已扩到 ${DISK_SIZE}G，但分区和文件系统还停在 ${IMAGE_DISK_GB}G）"
    echo "   两个坑先说清楚（都已实测确认）："
    echo "     · fstab 里虽然带 x-systemd.growfs，但 systemd-growfs 只扩【文件系统】、"
    echo "       不扩【分区】。实测把磁盘放到 60G，根分区仍停在 49.9G，光靠它没用。"
    echo "     · 镜像里开箱【没有任何分区工具】（growpart / sfdisk / parted / fdisk 都没有），"
    echo "       所以必须先联网装一个。"
    echo "   进系统后执行："
    echo "     apt-get update && apt-get install -y cloud-guest-utils"
    echo "     growpart /dev/sda 1     # 本脚本用 scsi0，对应 /dev/sda；若改 virtio-blk 则是 /dev/vda"
    echo "     resize2fs /dev/sda1     # 在线扩容，不用重启"
    echo "   实测结果：磁盘 60G -> 分区 59.9G / 文件系统 59G，重启后保持；"
    echo "             growpart 会保留分区起始扇区与 PARTUUID，fstab 不受影响。"
    echo
else
    echo "3) 磁盘保持 ${IMAGE_DISK_GB}G，分区和文件系统已是 ${IMAGE_DISK_GB}G，无需任何扩容操作。"
    echo
fi
echo -e "${CYAN}说明：本镜像未安装 cloud-init，所以没有加 cloud-init 驱动；"
echo -e "      DHCP、SSH、root 密码都已在镜像内固化，开机即用，无需任何初始化操作。${NC}"
echo -e "${GREEN}======================================${NC}"
