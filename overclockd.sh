#!/bin/bash
# =============================================================================
# RaeHost Node Performance Tuning Script
# https://github.com/raehost/node-setup
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() {
    echo -e "\n${BOLD}${CYAN}┌──────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│  $1${NC}"
    echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────┘${NC}"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Script harus dijalankan sebagai root."
        exit 1
    fi
}

confirm() {
    read -rp "$(echo -e "${YELLOW}[?]${NC} $1 [y/N]: ")" resp
    [[ "$resp" =~ ^[Yy]$ ]]
}

# =============================================================================
# LOGO
# =============================================================================

print_logo() {
    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗  █████╗ ███████╗██╗  ██╗ ██████╗ ███████╗████████╗"
    echo "  ██╔══██╗██╔══██╗██╔════╝██║  ██║██╔═══██╗██╔════╝╚══██╔══╝"
    echo "  ██████╔╝███████║█████╗  ███████║██║   ██║███████╗   ██║   "
    echo "  ██╔══██╗██╔══██║██╔══╝  ██╔══██║██║   ██║╚════██║   ██║   "
    echo "  ██║  ██║██║  ██║███████╗██║  ██║╚██████╔╝███████║   ██║   "
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝   "
    echo -e "${NC}"
    echo -e "${DIM}  Node Performance Tuning Script — game server optimized${NC}"
    echo -e "${DIM}  https://raehost.com${NC}"
    echo ""
}

# =============================================================================
# DETECT VM TYPE
# =============================================================================

detect_vm_type() {
    local RESULT="none"

    # systemd-detect-virt: returns "none" string if bare metal
    if command -v systemd-detect-virt &>/dev/null; then
        local VIRT
        VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
        if [[ "$VIRT" != "none" && -n "$VIRT" ]]; then
            RESULT="$VIRT"
        fi
    fi

    # DMI fallback
    if [[ "$RESULT" == "none" ]]; then
        if   grep -qi "vmware"     /sys/class/dmi/id/product_name 2>/dev/null; then RESULT="vmware"
        elif grep -qi "virtualbox" /sys/class/dmi/id/product_name 2>/dev/null; then RESULT="virtualbox"
        elif grep -qi "KVM"        /sys/class/dmi/id/product_name 2>/dev/null; then RESULT="kvm"
        elif grep -qi "microsoft"  /sys/class/dmi/id/sys_vendor   2>/dev/null; then RESULT="hyperv"
        elif [[ -f /proc/1/environ ]] && grep -qi "container=lxc" /proc/1/environ 2>/dev/null; then RESULT="lxc"
        fi
    fi

    # cpuinfo hypervisor flag (only if all above passed)
    if [[ "$RESULT" == "none" ]]; then
        grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null && RESULT="unknown-vm"
    fi

    echo "$RESULT"
}

# =============================================================================
# DETECT CPU
# =============================================================================

detect_cpu() {
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2 | xargs)
    CPU_VENDOR_ID=$(grep -m1 'vendor_id' /proc/cpuinfo | cut -d':' -f2 | xargs)
    CPU_CORES=$(nproc)
    CPU_THREADS=$(grep -c processor /proc/cpuinfo)
    CPU_FLAGS=$(grep -m1 'flags' /proc/cpuinfo | cut -d':' -f2)

    if echo "$CPU_VENDOR_ID" | grep -qi "AuthenticAMD"; then
        CPU_VENDOR="AMD"
    elif echo "$CPU_VENDOR_ID" | grep -qi "GenuineIntel"; then
        CPU_VENDOR="Intel"
    else
        CPU_VENDOR="Unknown"
    fi

    CPU_FAMILY="Generic"
    MODEL_LOWER=$(echo "$CPU_MODEL" | tr '[:upper:]' '[:lower:]')

    if [[ "$CPU_VENDOR" == "AMD" ]]; then
        echo "$MODEL_LOWER" | grep -q "epyc"         && CPU_FAMILY="AMD EPYC (Server)"
        echo "$MODEL_LOWER" | grep -q "threadripper" && CPU_FAMILY="AMD Threadripper (HEDT)"
        echo "$MODEL_LOWER" | grep -q "ryzen 9"      && CPU_FAMILY="AMD Ryzen 9 (Desktop/WS)"
        echo "$MODEL_LOWER" | grep -q "ryzen 7"      && CPU_FAMILY="AMD Ryzen 7 (Desktop)"
        echo "$MODEL_LOWER" | grep -q "ryzen 5"      && CPU_FAMILY="AMD Ryzen 5 (Desktop)"
    elif [[ "$CPU_VENDOR" == "Intel" ]]; then
        echo "$MODEL_LOWER" | grep -q "xeon"        && CPU_FAMILY="Intel Xeon (Server)"
        echo "$MODEL_LOWER" | grep -q "core ultra"  && CPU_FAMILY="Intel Core Ultra"
        echo "$MODEL_LOWER" | grep -q "4565p\|4585p" && CPU_FAMILY="Intel Core Ultra (Server)"
        echo "$MODEL_LOWER" | grep -q "i9"          && CPU_FAMILY="Intel Core i9"
        echo "$MODEL_LOWER" | grep -q "i7"          && CPU_FAMILY="Intel Core i7"
        echo "$MODEL_LOWER" | grep -q "i5"          && CPU_FAMILY="Intel Core i5"
    fi

    AES_NI=$(echo "$CPU_FLAGS" | grep -qw "aes"    && echo "✔ Enabled"  || echo "✘ Disabled")
    VMX=$(   echo "$CPU_FLAGS" | grep -qw "vmx"    && echo "✔ Enabled (VT-x)" || \
             echo "$CPU_FLAGS" | grep -qw "svm"    && echo "✔ Enabled (AMD-V)" || echo "✘ Disabled")
    AVX2=$(  echo "$CPU_FLAGS" | grep -qw "avx2"   && echo "✔" || echo "✘")
    AVX512=$(echo "$CPU_FLAGS" | grep -qw "avx512f" && echo "✔" || echo "✘")

    CPU_CUR_FREQ=$(grep -m1 'cpu MHz' /proc/cpuinfo | cut -d':' -f2 | xargs | cut -d'.' -f1 2>/dev/null || echo "N/A")
    CPU_MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null | awk '{printf "%d", $1/1000}' || echo "N/A")
}

# =============================================================================
# DETECT SYSTEM
# =============================================================================

detect_system() {
    section "SYSTEM INFORMATION"

    OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    KERNEL=$(uname -r)
    ARCH=$(uname -m)

    UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
    UPTIME_STR="$((UPTIME_SEC/86400)) days, $(( (UPTIME_SEC%86400)/3600 )) hours, $(( (UPTIME_SEC%3600)/60 )) minutes"

    VM_TYPE=$(detect_vm_type)
    VM_DISPLAY=$([[ "$VM_TYPE" == "none" ]] && echo "NONE (Bare Metal)" || echo "$VM_TYPE")
    detect_cpu

    RAM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    RAM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    RAM_TOTAL_GiB=$(echo "scale=1; $RAM_TOTAL_KB/1024/1024" | bc)
    RAM_USED_GiB=$(echo "scale=1; ($RAM_TOTAL_KB-$RAM_AVAIL_KB)/1024/1024" | bc)

    if command -v dmidecode &>/dev/null; then
        RAM_SPEED=$(dmidecode -t memory 2>/dev/null | grep -i "configured memory speed" | head -1 | grep -oP '\d+ MT/s' || echo "N/A")
        RAM_TYPE=$(dmidecode -t memory 2>/dev/null | grep -i "^\s*Type:" | grep -v "Unknown\|Error\|Detail" | head -1 | awk '{print $2}' || echo "N/A")
    else
        RAM_SPEED="N/A (install dmidecode)"
        RAM_TYPE="N/A"
    fi

    SWAP_TOTAL=$(free -h | awk '/^Swap:/{print $2}')
    SWAP_USED=$(free -h | awk '/^Swap:/{print $3}')
    DISK_INFO=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used, "$4" avail)"}')

    DEFAULT_IF=$(ip route | awk '/default/{print $5}' | head -1)
    NET_SPEED=$(cat /sys/class/net/${DEFAULT_IF}/speed 2>/dev/null || echo "N/A")

    IPV4_CHECK=$(curl -s4 --max-time 4 https://ipinfo.io/ip 2>/dev/null || echo "")
    IPV6_CHECK=$(curl -s6 --max-time 4 https://ipinfo.io/ip 2>/dev/null || echo "")
    IPV4_STATUS=$([[ -n "$IPV4_CHECK" ]] && echo "✔ Online ($IPV4_CHECK)" || echo "✘ Offline")
    IPV6_STATUS=$([[ -n "$IPV6_CHECK" ]] && echo "✔ Online" || echo "✘ Offline")

    IP_INFO=$(curl -s --max-time 5 https://ipinfo.io 2>/dev/null || echo "{}")
    IP_ISP=$(echo "$IP_INFO"    | grep '"org"'      | cut -d'"' -f4 || echo "N/A")
    IP_ASN=$(echo "$IP_ISP"     | awk '{print $1}')
    IP_ORG=$(echo "$IP_ISP"     | cut -d' ' -f2-)
    IP_CITY=$(echo "$IP_INFO"   | grep '"city"'     | cut -d'"' -f4 || echo "N/A")
    IP_REGION=$(echo "$IP_INFO" | grep '"region"'   | cut -d'"' -f4 || echo "N/A")
    IP_COUNTRY=$(echo "$IP_INFO"| grep '"country"'  | cut -d'"' -f4 || echo "N/A")

    CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    CURRENT_SWAP=$(sysctl -n vm.swappiness 2>/dev/null || echo "N/A")
    CURRENT_THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\w+\]' | tr -d '[]' || echo "N/A")
    CURRENT_TCP=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
    CURRENT_NOFILE=$(ulimit -n)

    echo ""
    echo -e "  ${BOLD}Basic System Information${NC}"
    echo -e "  ─────────────────────────────────────────────────"
    printf "  %-24s: %s\n" "Uptime"      "$UPTIME_STR"
    printf "  %-24s: %s\n" "Distro"      "$OS"
    printf "  %-24s: %s\n" "Kernel"      "$KERNEL ($ARCH)"
    printf "  %-24s: %s\n" "VM Type"     "$VM_DISPLAY"
    echo ""
    echo -e "  ${BOLD}CPU${NC}"
    echo -e "  ─────────────────────────────────────────────────"
    printf "  %-24s: %s\n" "Processor"   "$CPU_MODEL"
    printf "  %-24s: %s\n" "Family"      "$CPU_FAMILY"
    printf "  %-24s: %s\n" "CPU Cores"   "$CPU_CORES cores / $CPU_THREADS threads"
    printf "  %-24s: %s MHz (cur) / %s MHz (max)\n" "Frequency" "$CPU_CUR_FREQ" "$CPU_MAX_FREQ"
    printf "  %-24s: %s\n" "AES-NI"      "$AES_NI"
    printf "  %-24s: %s\n" "VM-x/AMD-V"  "$VMX"
    printf "  %-24s: %s / %s\n" "AVX2 / AVX-512" "$AVX2" "$AVX512"
    echo ""
    echo -e "  ${BOLD}Memory${NC}"
    echo -e "  ─────────────────────────────────────────────────"
    printf "  %-24s: %s GiB total / %s GiB used\n" "RAM" "$RAM_TOTAL_GiB" "$RAM_USED_GiB"
    printf "  %-24s: %s\n" "RAM Type"    "$RAM_TYPE"
    printf "  %-24s: %s\n" "RAM Speed"   "$RAM_SPEED"
    printf "  %-24s: %s / %s\n" "Swap" "$SWAP_USED" "$SWAP_TOTAL"
    echo ""
    echo -e "  ${BOLD}Storage${NC}"
    echo -e "  ─────────────────────────────────────────────────"
    printf "  %-24s: %s\n" "Disk (/)" "$DISK_INFO"
    lsblk -d -o NAME,SIZE,ROTA,TYPE,MODEL 2>/dev/null | grep -v "loop\|NAME" | while read -r NAME SIZE ROTA TYPE MODEL; do
        [[ "$TYPE" == "disk" ]] || continue
        DTYPE=$([[ "$ROTA" == "0" ]] && echo "NVMe/SSD" || echo "HDD")
        printf "  %-24s: %s (%s) %s\n" "  /dev/$NAME" "$SIZE" "$DTYPE" "$MODEL"
    done
    echo ""
    echo -e "  ${BOLD}Network${NC}"
    echo -e "  ─────────────────────────────────────────────────"
    printf "  %-24s: %s (%sMbps)\n" "Interface"  "$DEFAULT_IF" "$NET_SPEED"
    printf "  %-24s: %s / %s\n"     "IPv4/IPv6"  "$IPV4_STATUS" "$IPV6_STATUS"
    printf "  %-24s: %s\n"          "ISP"        "$IP_ORG"
    printf "  %-24s: %s\n"          "ASN"        "$IP_ASN"
    printf "  %-24s: %s, %s, %s\n"  "Location"   "$IP_CITY" "$IP_REGION" "$IP_COUNTRY"
    echo ""
    echo -e "  ${BOLD}Current Tuning State${NC}"
    echo -e "  ─────────────────────────────────────────────────"
    printf "  %-24s: %s\n" "CPU Governor"    "$CURRENT_GOV"
    printf "  %-24s: %s\n" "vm.swappiness"   "$CURRENT_SWAP"
    printf "  %-24s: %s\n" "Hugepages"       "$CURRENT_THP"
    printf "  %-24s: %s\n" "TCP CC"          "$CURRENT_TCP"
    printf "  %-24s: %s\n" "nofile limit"    "$CURRENT_NOFILE"
    printf "  %-24s: %s\n" "BBR loaded"      "$(lsmod | grep -q tcp_bbr && echo yes || echo no)"
    echo ""
}

# =============================================================================
# BAREMETAL CHECK
# =============================================================================

check_baremetal() {
    VM_TYPE=$(detect_vm_type)
    if [[ "$VM_TYPE" != "none" ]]; then
        echo ""
        error "VM environment terdeteksi: ${VM_TYPE}"
        error "Script ini hanya untuk bare metal node."
        echo ""
        warn "Alasan pembatasan:"
        warn "  - CPU governor & C-state tidak efektif di VM"
        warn "  - RAM speed dikontrol oleh hypervisor, bukan guest OS"
        warn "  - Banyak tuning sudah di-handle di level hypervisor"
        echo ""
        warn "Jika yakin ini bare metal (false positive), jalankan:"
        warn "  bash overclockd.sh --force"
        echo ""
        exit 1
    fi
    log "Bare metal confirmed ✔"
}

# =============================================================================
# CPU TUNING — Universal: Intel, AMD, EPYC, Ryzen, Xeon, semua generasi
# =============================================================================

tune_cpu() {
    section "CPU TUNING"

    detect_cpu
    info "Vendor   : $CPU_VENDOR"
    info "Family   : $CPU_FAMILY"
    info "Model    : $CPU_MODEL"

    # cpufreq availability
    if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        warn "cpufreq tidak tersedia, mencoba load driver..."
        if [[ "$CPU_VENDOR" == "AMD" ]]; then
            modprobe amd_pstate 2>/dev/null || modprobe acpi-cpufreq 2>/dev/null || true
        elif [[ "$CPU_VENDOR" == "Intel" ]]; then
            modprobe intel_pstate 2>/dev/null || modprobe acpi-cpufreq 2>/dev/null || true
        else
            modprobe acpi-cpufreq 2>/dev/null || true
        fi
    fi

    if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        warn "cpufreq tidak tersedia setelah load driver. Skip governor tuning."
    else
        AVAIL_GOVS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
        CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        info "Available governors : $AVAIL_GOVS"
        info "Current governor    : $CURRENT_GOV"

        # Pilih governor terbaik
        TARGET_GOV=""
        if   echo "$AVAIL_GOVS" | grep -qw "performance"; then TARGET_GOV="performance"
        elif echo "$AVAIL_GOVS" | grep -qw "schedutil";   then TARGET_GOV="schedutil"; warn "Fallback ke schedutil"
        elif echo "$AVAIL_GOVS" | grep -qw "ondemand";    then TARGET_GOV="ondemand";  warn "Fallback ke ondemand"
        else warn "Tidak ada governor yang cocok, skip."; fi

        if [[ -n "$TARGET_GOV" ]]; then
            if [[ "$CURRENT_GOV" == "$TARGET_GOV" ]]; then
                log "Governor sudah $TARGET_GOV"
            else
                echo "$TARGET_GOV" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
                log "CPU governor → $TARGET_GOV (semua core)"

                apt-get install -y cpufrequtils -qq 2>/dev/null && \
                    echo "GOVERNOR=\"$TARGET_GOV\"" > /etc/default/cpufrequtils && \
                    log "cpufrequtils configured"

                cat > /etc/systemd/system/cpu-performance.service << EOF
[Unit]
Description=Set CPU Governor to $TARGET_GOV
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo $TARGET_GOV | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable cpu-performance.service > /dev/null 2>&1
                log "Systemd service created (persistent)"
            fi
        fi
    fi

    # ── AMD specific ──────────────────────────────────────────────────────────
    if [[ "$CPU_VENDOR" == "AMD" ]]; then
        # AMD P-state EPP (Zen 3+: Ryzen 5000+, EPYC Genoa+)
        PSTATE_STATUS=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo "N/A")
        if [[ "$PSTATE_STATUS" != "N/A" ]]; then
            info "AMD P-state status: $PSTATE_STATUS"
            for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
                echo "performance" > "$f" 2>/dev/null || true
            done
            log "AMD EPP → performance"
        fi

        # Disable AMD C6 state (semua generasi Zen yang support)
        C6_DISABLED=0
        for cstate in /sys/devices/system/cpu/cpu*/cpuidle/state*/name; do
            STATE_NAME=$(cat "$cstate" 2>/dev/null || echo "")
            if [[ "$STATE_NAME" == "C6" ]]; then
                STATE_DIR=$(dirname "$cstate")
                echo 1 > "$STATE_DIR/disable" 2>/dev/null && C6_DISABLED=1 || true
            fi
        done
        [[ $C6_DISABLED -eq 1 ]] && log "AMD C6 state disabled" || info "C6 state tidak ditemukan (normal di beberapa CPU)"

        # EPYC specific: disable NUMA balancing sangat penting
        if echo "$CPU_FAMILY" | grep -qi "EPYC\|Threadripper"; then
            sysctl -w kernel.numa_balancing=0 > /dev/null 2>/dev/null || true
            log "EPYC/TR: NUMA balancing disabled"
        fi
    fi

    # ── Intel specific ────────────────────────────────────────────────────────
    if [[ "$CPU_VENDOR" == "Intel" ]]; then
        # Intel EPP
        for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            echo "performance" > "$f" 2>/dev/null || true
        done
        log "Intel EPP → performance (if supported)"

        # Intel C-state via intel_idle (semua generasi)
        if [[ -f /sys/module/intel_idle/parameters/max_cstate ]]; then
            echo 1 > /sys/module/intel_idle/parameters/max_cstate
            if ! grep -q "intel_idle.max_cstate" /etc/default/grub 2>/dev/null; then
                sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_idle.max_cstate=1 processor.max_cstate=1"/' /etc/default/grub
                update-grub > /dev/null 2>&1 && log "Intel C-state → 1 (GRUB updated, butuh reboot)"
            else
                log "Intel C-state sudah di GRUB"
            fi
        fi

        # Intel Turbo Boost — pastikan enabled
        if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
            echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null && log "Intel Turbo Boost → enabled"
        fi
    fi
}

# =============================================================================
# MEMORY TUNING
# =============================================================================

tune_memory() {
    section "MEMORY TUNING"

    sysctl -w vm.swappiness=60 > /dev/null
    grep -q "^vm.swappiness" /etc/sysctl.conf && \
        sed -i 's/^vm.swappiness=.*/vm.swappiness=60/' /etc/sysctl.conf || \
        echo "vm.swappiness=60" >> /etc/sysctl.conf
    log "vm.swappiness = 60"

    sysctl -w vm.dirty_ratio=10 > /dev/null
    sysctl -w vm.dirty_background_ratio=5 > /dev/null
    grep -q "^vm.dirty_ratio" /etc/sysctl.conf && \
        sed -i 's/^vm.dirty_ratio=.*/vm.dirty_ratio=10/' /etc/sysctl.conf || \
        echo "vm.dirty_ratio=10" >> /etc/sysctl.conf
    grep -q "^vm.dirty_background_ratio" /etc/sysctl.conf && \
        sed -i 's/^vm.dirty_background_ratio=.*/vm.dirty_background_ratio=5/' /etc/sysctl.conf || \
        echo "vm.dirty_background_ratio=5" >> /etc/sysctl.conf
    log "vm.dirty_ratio=10, vm.dirty_background_ratio=5"

    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
    cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
Before=basic.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes
[Install]
WantedBy=basic.target
EOF
    systemctl daemon-reload
    systemctl enable disable-thp.service > /dev/null 2>&1
    log "Transparent Hugepages → never (persistent)"

    if [[ -f /proc/sys/kernel/numa_balancing ]]; then
        sysctl -w kernel.numa_balancing=0 > /dev/null
        grep -q "^kernel.numa_balancing" /etc/sysctl.conf && \
            sed -i 's/^kernel.numa_balancing=.*/kernel.numa_balancing=0/' /etc/sysctl.conf || \
            echo "kernel.numa_balancing=0" >> /etc/sysctl.conf
        log "NUMA auto-balancing → disabled"
    fi

    sysctl -w vm.overcommit_memory=1 > /dev/null
    grep -q "^vm.overcommit_memory" /etc/sysctl.conf && \
        sed -i 's/^vm.overcommit_memory=.*/vm.overcommit_memory=1/' /etc/sysctl.conf || \
        echo "vm.overcommit_memory=1" >> /etc/sysctl.conf
    log "vm.overcommit_memory=1 (JVM/Java friendly)"
}

# =============================================================================
# SWAP SETUP
# =============================================================================

setup_swap() {
    section "SWAP SETUP"

    # Tanya dulu mau setup swap atau tidak
    if ! confirm "Setup swapfile?"; then
        warn "Swap setup dilewati."
        return
    fi

    # Tanya ukuran swap
    AVAIL_GB=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    info "Available disk: ~${AVAIL_GB}GB"
    echo ""
    read -rp "$(echo -e "${YELLOW}[?]${NC} Ukuran swapfile dalam GB (contoh: 32, 64, 128): ")" SWAP_SIZE_INPUT

    # Validasi input: harus angka positif
    if ! [[ "$SWAP_SIZE_INPUT" =~ ^[0-9]+$ ]] || [[ "$SWAP_SIZE_INPUT" -le 0 ]]; then
        error "Input tidak valid: '$SWAP_SIZE_INPUT'. Harus angka positif. Skip swap setup."
        return
    fi

    SWAP_SIZE=$SWAP_SIZE_INPUT

    # Cek cukup disk space (tambah 2GB buffer)
    REQUIRED_GB=$((SWAP_SIZE + 2))
    if [[ $AVAIL_GB -lt $REQUIRED_GB ]]; then
        error "Disk tidak cukup untuk swapfile ${SWAP_SIZE}GB. Available: ${AVAIL_GB}GB, Required: ${REQUIRED_GB}GB."
        return
    fi

    # Handle existing swap
    EXISTING_SWAP=$(swapon --show 2>/dev/null)
    if [[ -n "$EXISTING_SWAP" ]]; then
        info "Swap aktif saat ini:"
        swapon --show
        echo ""
        if ! confirm "Hapus swap lama dan ganti dengan swapfile ${SWAP_SIZE}GB?"; then
            warn "Swap setup dilewati."
            return
        fi
        swapoff -a
        [[ -f /swapfile ]] && rm -f /swapfile && log "Swapfile lama dihapus"
        sed -i '/swap/d' /etc/fstab
        log "Swap entries lama dihapus dari fstab"
    fi

    info "Membuat swapfile ${SWAP_SIZE}GB..."
    fallocate -l "${SWAP_SIZE}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swapfile ${SWAP_SIZE}GB aktif dan persistent"

    # Konfirmasi
    SWAP_ACTUAL=$(swapon --show --noheadings | awk '{print $3}')
    info "Swap aktif sekarang: ${SWAP_ACTUAL}"
}

# =============================================================================
# NETWORK TUNING
# =============================================================================

tune_network() {
    section "NETWORK TUNING"

    modprobe tcp_bbr 2>/dev/null && log "BBR module loaded" || warn "BBR tidak tersedia di kernel ini"
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true

    # Hapus block lama kalau ada
    sed -i '/# RaeHost Network Tuning/,/^$/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf << 'EOF'

# RaeHost Network Tuning
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=65535
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
EOF

    if lsmod | grep -q tcp_bbr; then
        printf '\nnet.ipv4.tcp_congestion_control=bbr\nnet.core.default_qdisc=fq\n' >> /etc/sysctl.conf
        log "TCP congestion control → BBR + FQ"
    else
        warn "BBR tidak loaded, skip override congestion control"
    fi

    sysctl -p > /dev/null 2>&1
    log "Network sysctl applied"
}

# =============================================================================
# FILE DESCRIPTOR LIMITS
# =============================================================================

tune_limits() {
    section "FILE DESCRIPTOR LIMITS"

    CURRENT_LIMIT=$(ulimit -n)
    info "Current nofile: $CURRENT_LIMIT"

    if [[ $CURRENT_LIMIT -ge 65536 ]]; then
        log "nofile sudah >= 65536, skip."
        return
    fi

    grep -q "nofile 65536" /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf << 'EOF'

# RaeHost
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
    log "limits.conf updated"

    grep -q "DefaultLimitNOFILE=65536" /etc/systemd/system.conf 2>/dev/null || \
        echo "DefaultLimitNOFILE=65536" >> /etc/systemd/system.conf
    grep -q "DefaultLimitNOFILE=65536" /etc/systemd/user.conf 2>/dev/null || \
        echo "DefaultLimitNOFILE=65536" >> /etc/systemd/user.conf

    systemctl daemon-reexec
    log "systemd limits updated"
    warn "Perlu logout/login ulang agar nofile berlaku di session ini"
}

# =============================================================================
# DOCKER TUNING
# =============================================================================

tune_docker() {
    section "DOCKER TUNING"

    if ! command -v docker &>/dev/null; then
        warn "Docker tidak ditemukan, skip."
        return
    fi

    DOCKER_CONFIG="/etc/docker/daemon.json"
    if [[ -f "$DOCKER_CONFIG" ]]; then
        warn "daemon.json sudah ada, skip (edit manual jika perlu)."
        return
    fi

    cat > "$DOCKER_CONFIG" << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" },
    "default-ulimits": {
        "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
    },
    "storage-driver": "overlay2"
}
EOF
    systemctl restart docker
    log "Docker daemon.json configured"
}

# =============================================================================
# IRQ BALANCE
# =============================================================================

tune_irq() {
    section "IRQ AFFINITY"
    command -v irqbalance &>/dev/null || apt-get install -y irqbalance -qq
    systemctl enable irqbalance > /dev/null 2>&1
    systemctl restart irqbalance
    log "irqbalance enabled dan running"
}

# =============================================================================
# VERIFY
# =============================================================================

verify() {
    section "VERIFICATION SUMMARY"
    echo ""
    printf "  %-30s: %s\n" "CPU Governor"          "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
    printf "  %-30s: %s\n" "Transparent Hugepages" "$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -oP '\[\w+\]' | tr -d '[]')"
    printf "  %-30s: %s\n" "vm.swappiness"         "$(sysctl -n vm.swappiness)"
    printf "  %-30s: %s\n" "vm.dirty_ratio"        "$(sysctl -n vm.dirty_ratio)"
    printf "  %-30s: %s\n" "vm.overcommit_memory"  "$(sysctl -n vm.overcommit_memory)"
    printf "  %-30s: %s\n" "TCP Congestion Ctrl"   "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf "  %-30s: %s\n" "BBR Loaded"            "$(lsmod | grep -q tcp_bbr && echo yes || echo no)"
    printf "  %-30s: %s\n" "Swap Active"           "$(swapon --show --noheadings 2>/dev/null | awk '{print $1,$3}' || echo none)"
    printf "  %-30s: %s\n" "irqbalance"            "$(systemctl is-active irqbalance 2>/dev/null)"
    printf "  %-30s: %s\n" "Docker"                "$(systemctl is-active docker 2>/dev/null || echo 'not installed')"
    printf "  %-30s: %s\n" "nofile (systemd)"      "$(grep DefaultLimitNOFILE /etc/systemd/system.conf 2>/dev/null | cut -d= -f2 || echo 'not set')"
    echo ""
    warn "Butuh reboot untuk fully berlaku:"
    warn "  - C-state changes (Intel GRUB)"
    warn "  - nofile limit (logout/login)"
    warn "  - BBR module (jika baru pertama kali)"
    echo ""
}

# =============================================================================
# INTERACTIVE MENU
# =============================================================================

print_menu() {
    echo ""
    echo -e "${BOLD}  Pilih tuning yang ingin dijalankan:${NC}"
    echo -e "  ${DIM}(tekan Enter untuk toggle, A untuk semua, N untuk none, kemudian ketik 'run')${NC}"
    echo ""
    local i=1
    for key in "${!MENU_ITEMS[@]}"; do
        local label="${MENU_ITEMS[$key]}"
        local state="${MENU_STATE[$key]}"
        local indicator
        [[ "$state" == "1" ]] && indicator="${GREEN}[✓]${NC}" || indicator="${RED}[ ]${NC}"
        printf "  %s %s. %s\n" "$(echo -e $indicator)" "$i" "$label"
        ((i++))
    done
    echo ""
}

interactive_menu() {
    # Define menu items: key → label
    declare -gA MENU_ITEMS=(
        [cpu]="CPU Governor & C-state tuning"
        [memory]="Memory tuning (THP, swappiness, dirty ratio)"
        [swap]="Swap setup"
        [network]="Network tuning (BBR, TCP buffers)"
        [limits]="File descriptor limits (nofile → 65536)"
        [docker]="Docker daemon tuning"
        [irq]="IRQ balance"
    )

    # Default semua ON
    declare -gA MENU_STATE=(
        [cpu]="1"
        [memory]="1"
        [swap]="1"
        [network]="1"
        [limits]="1"
        [docker]="1"
        [irq]="1"
    )

    # Ordered keys for numbered menu
    MENU_ORDER=(cpu memory swap network limits docker irq)

    while true; do
        print_menu

        read -rp "$(echo -e "${YELLOW}[?]${NC} Nomor untuk toggle / A = semua ON / N = semua OFF / run = jalankan / q = batal: ")" INPUT
        INPUT=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' | xargs)

        case "$INPUT" in
            run)
                # Cek minimal satu dipilih
                local any_selected=0
                for key in "${MENU_ORDER[@]}"; do
                    [[ "${MENU_STATE[$key]}" == "1" ]] && any_selected=1
                done
                if [[ $any_selected -eq 0 ]]; then
                    warn "Tidak ada tuning yang dipilih."
                else
                    break
                fi
                ;;
            a)
                for key in "${MENU_ORDER[@]}"; do MENU_STATE[$key]="1"; done
                ;;
            n)
                for key in "${MENU_ORDER[@]}"; do MENU_STATE[$key]="0"; done
                ;;
            q)
                info "Dibatalkan."
                exit 0
                ;;
            [1-9])
                local idx=$((INPUT - 1))
                if [[ $idx -ge 0 && $idx -lt ${#MENU_ORDER[@]} ]]; then
                    local key="${MENU_ORDER[$idx]}"
                    [[ "${MENU_STATE[$key]}" == "1" ]] && MENU_STATE[$key]="0" || MENU_STATE[$key]="1"
                else
                    warn "Nomor tidak valid."
                fi
                ;;
            *)
                warn "Input tidak dikenali. Ketik nomor, A, N, run, atau q."
                ;;
        esac
    done

    echo ""
    echo -e "${BOLD}  Tuning yang akan dijalankan:${NC}"
    for key in "${MENU_ORDER[@]}"; do
        [[ "${MENU_STATE[$key]}" == "1" ]] && echo -e "  ${GREEN}[✓]${NC} ${MENU_ITEMS[$key]}"
    done
    echo ""

    if ! confirm "Konfirmasi jalankan?"; then
        info "Dibatalkan."
        exit 0
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    require_root
    print_logo

    FORCE=0
    [[ "${1:-}" == "--force" ]] && FORCE=1

    detect_system

    if [[ $FORCE -eq 0 ]]; then
        check_baremetal
    else
        warn "--force flag: melewati VM check."
    fi

    interactive_menu

    [[ "${MENU_STATE[cpu]}"     == "1" ]] && tune_cpu
    [[ "${MENU_STATE[memory]}"  == "1" ]] && tune_memory
    [[ "${MENU_STATE[swap]}"    == "1" ]] && setup_swap
    [[ "${MENU_STATE[network]}" == "1" ]] && tune_network
    [[ "${MENU_STATE[limits]}"  == "1" ]] && tune_limits
    [[ "${MENU_STATE[docker]}"  == "1" ]] && tune_docker
    [[ "${MENU_STATE[irq]}"     == "1" ]] && tune_irq

    verify

    echo -e "\n${BOLD}${GREEN}  ✔ Tuning selesai! Reboot direkomendasikan.${NC}\n"
}

main "$@"
