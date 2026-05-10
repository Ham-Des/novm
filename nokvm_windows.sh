#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# With Windows 11 Support
# =============================

display_header() {
    clear
    cat << "EOF"
========================================================================
  _    _  ____  _____ _   _  _____ ____   ______     ________
 | |  | |/ __ \|  __ \_   _| \ | |/ ____|  _ \ / __ \ \   / /___  /
 | |__| | |  | | |__) || | |  \| | |  __| |_) | |  | \ \_/ /   / / 
 |  __  | |  | |  ___/ | | |   \ | | |_ |  _ <| |  | |\   /   / /  
 | |  | | |__| | |    _| |_| |\  | |__| | |_) | |__| | | |   / /__ 
 |_|  |_|\____/|_|   |_____|_| \_|\_____|____/ \____/  |_|  /_____|
                    POWERED BY HOPINGBOYZ + WINDOWS SUPPORT
========================================================================
EOF
    echo
}

print_status() {
    local type=$1
    local message=$2
    case $type in
        "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN")    echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *)         echo "[$type] $message" ;;
    esac
}

validate_input() {
    local type=$1
    local value=$2
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"; return 1
            fi ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"; return 1
            fi ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"; return 1
            fi ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"; return 1
            fi ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore"; return 1
            fi ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "qemu-img")
    local missing_deps=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Ubuntu/Debian, try: sudo apt install qemu-system wget"
        exit 1
    fi

    # cloud-localds only needed for Linux VMs
    if ! command -v cloud-localds &> /dev/null; then
        print_status "WARN" "cloud-localds not found — Linux cloud VMs won't work, but Windows is fine!"
    fi
}

cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT VNC_PORT RDP_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED IS_WINDOWS VIRTIO_ISO
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="${OS_TYPE:-linux}"
IS_WINDOWS="${IS_WINDOWS:-false}"
CODENAME="${CODENAME:-}"
IMG_URL="${IMG_URL:-}"
HOSTNAME="${HOSTNAME:-}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="${SSH_PORT:-2222}"
VNC_PORT="${VNC_PORT:-5900}"
RDP_PORT="${RDP_PORT:-3389}"
GUI_MODE="${GUI_MODE:-false}"
PORT_FORWARDS="${PORT_FORWARDS:-}"
IMG_FILE="$IMG_FILE"
SEED_FILE="${SEED_FILE:-}"
VIRTIO_ISO="${VIRTIO_ISO:-}"
CREATED="$CREATED"
EOF
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# ===========================
# WINDOWS VM FUNCTIONS
# ===========================

setup_novnc() {
    if ! command -v websockify &> /dev/null; then
        print_status "INFO" "Installing noVNC for browser access..."
        apt install -y novnc websockify 2>/dev/null || true
    fi
}

start_novnc() {
    local vnc_port=$1
    local novnc_port=${2:-6080}

    # Kill existing websockify on that port
    fuser -k ${novnc_port}/tcp 2>/dev/null || true
    sleep 1

    if command -v websockify &> /dev/null; then
        websockify --web=/usr/share/novnc ${novnc_port} localhost:${vnc_port} &
        sleep 1
        print_status "SUCCESS" "noVNC browser access started!"
        print_status "INFO" "Open in browser: http://$(hostname -I | awk '{print $1}'):${novnc_port}/vnc.html"
    else
        print_status "WARN" "websockify not found. Use a VNC client to connect to port ${vnc_port}"
    fi
}

download_virtio() {
    local virtio_path="$VM_DIR/virtio-win.iso"
    if [[ ! -f "$virtio_path" ]]; then
        print_status "INFO" "Downloading VirtIO drivers (needed for Windows disk detection)..."
        wget -q --show-progress "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" -O "$virtio_path"
        print_status "SUCCESS" "VirtIO drivers downloaded!"
    else
        print_status "INFO" "VirtIO drivers already exist, skipping download."
    fi
    echo "$virtio_path"
}

create_windows_vm() {
    print_status "INFO" "Setting up Windows 11 VM"

    # VM Name
    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: windows11): ")" VM_NAME
        VM_NAME="${VM_NAME:-windows11}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    # Windows ISO path
    local default_iso="/root/windows11.iso"
    while true; do
        read -p "$(print_status "INPUT" "Path to Windows 11 ISO (default: $default_iso): ")" WIN_ISO
        WIN_ISO="${WIN_ISO:-$default_iso}"
        if [[ -f "$WIN_ISO" ]]; then
            print_status "SUCCESS" "ISO found: $WIN_ISO"
            break
        else
            print_status "ERROR" "File not found: $WIN_ISO — please enter the correct path"
        fi
    done

    # Disk size
    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 500G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-500G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    # RAM
    while true; do
        read -p "$(print_status "INPUT" "RAM in MB (default: 65536 = 64GB): ")" MEMORY
        MEMORY="${MEMORY:-65536}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    # CPUs
    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 16): ")" CPUS
        CPUS="${CPUS:-16}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    # VNC Port
    while true; do
        read -p "$(print_status "INPUT" "VNC Port (default: 5900): ")" VNC_PORT
        VNC_PORT="${VNC_PORT:-5900}"
        if validate_input "port" "$VNC_PORT"; then break; fi
    done

    # RDP Port forward
    while true; do
        read -p "$(print_status "INPUT" "RDP Port forward (default: 3389): ")" RDP_PORT
        RDP_PORT="${RDP_PORT:-3389}"
        if validate_input "port" "$RDP_PORT"; then break; fi
    done

    # Download VirtIO
    VIRTIO_ISO=$(download_virtio)

    # Create disk image
    IMG_FILE="$VM_DIR/$VM_NAME.qcow2"
    print_status "INFO" "Creating ${DISK_SIZE} disk image..."
    qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
    print_status "SUCCESS" "Disk image created: $IMG_FILE"

    # Save config
    IS_WINDOWS=true
    OS_TYPE="windows"
    CODENAME="win11"
    IMG_URL=""
    HOSTNAME="windows11"
    USERNAME="Administrator"
    PASSWORD=""
    SSH_PORT=2222
    GUI_MODE=false
    PORT_FORWARDS=""
    SEED_FILE=""
    CREATED="$(date)"

    # Store ISO path in config
    cat > "$VM_DIR/$VM_NAME.conf" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="windows"
IS_WINDOWS="true"
WIN_ISO="$WIN_ISO"
VIRTIO_ISO="$VIRTIO_ISO"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
VNC_PORT="$VNC_PORT"
RDP_PORT="$RDP_PORT"
IMG_FILE="$IMG_FILE"
CREATED="$CREATED"
EOF

    print_status "SUCCESS" "Windows 11 VM '$VM_NAME' configured!"
    echo
    print_status "INFO" "Now starting the VM and Windows installer..."
    sleep 2
    start_windows_vm "$VM_NAME"
}

start_windows_vm() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"

    source "$config_file"

    local vnc_display=$(( VNC_PORT - 5900 ))

    print_status "INFO" "Starting Windows 11 VM: $vm_name"
    print_status "INFO" "RAM: ${MEMORY}MB | CPUs: $CPUS | Disk: $DISK_SIZE"
    print_status "INFO" "VNC Port: $VNC_PORT | RDP Port forward: $RDP_PORT"

    # Check if first boot (installer mode) or already installed
    local boot_from="dc"  # default: boot from cdrom first
    if [[ -f "$VM_DIR/$vm_name.installed" ]]; then
        boot_from="c"
        print_status "INFO" "Windows already installed — booting from disk"
    else
        print_status "INFO" "First boot — launching Windows installer"
        print_status "WARN" "When installer says 'No drives found' → click Load Driver → VirtIO CD → viostor → w11 → amd64"
    fi

    # Setup noVNC for browser access
    setup_novnc

    # Start QEMU
    qemu-system-x86_64 \
        -m "$MEMORY" \
        -smp "$CPUS" \
        -cpu qemu64 \
        -drive "file=$IMG_FILE,format=qcow2,if=virtio" \
        -drive "file=$WIN_ISO,media=cdrom,index=1" \
        -drive "file=$VIRTIO_ISO,media=cdrom,index=2" \
        -boot order="$boot_from" \
        -device virtio-net-pci,netdev=net0 \
        -netdev "user,id=net0,hostfwd=tcp::${RDP_PORT}-:3389" \
        -vnc "0.0.0.0:${vnc_display}" \
        -daemonize \
        -pidfile "$VM_DIR/$vm_name.pid"

    sleep 2

    # Start noVNC
    start_novnc "$VNC_PORT" 6080

    echo
    print_status "SUCCESS" "Windows 11 VM is running!"
    echo "========================================================"
    print_status "INFO" "Browser VNC: http://$(hostname -I | awk '{print $1}'):6080/vnc.html"
    print_status "INFO" "After Windows installs, RDP to: $(hostname -I | awk '{print $1}'):${RDP_PORT}"
    echo
    print_status "INFO" "After installation is complete, run:"
    print_status "INFO" "  touch $VM_DIR/$vm_name.installed"
    print_status "INFO" "Then restart the VM to boot from disk (no installer)"
    echo "========================================================"

    # Mark as installed prompt
    echo
    read -p "$(print_status "INPUT" "Once Windows finishes installing, press Enter to mark as installed: ")"
    touch "$VM_DIR/$vm_name.installed"
    print_status "SUCCESS" "Marked as installed! Next start will boot directly to Windows."
}

# ===========================
# LINUX VM FUNCTIONS (original)
# ===========================

create_new_vm() {
    print_status "INFO" "Creating a new VM"

    echo "  1) Windows 11"
    echo "  2) Linux (Ubuntu/Debian/etc)"
    read -p "$(print_status "INPUT" "Which type? (1-2): ")" vm_type

    if [[ "$vm_type" == "1" ]]; then
        create_windows_vm
        return
    fi

    print_status "INFO" "Select a Linux OS:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM with name '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then break; fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Enter password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then break
        else print_status "ERROR" "Password cannot be empty"; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then break; fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is already in use"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
        GUI_MODE=false
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then GUI_MODE=true; break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then break
        else print_status "ERROR" "Please answer y or n"; fi
    done

    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, press Enter for none): ")" PORT_FORWARDS

    IS_WINDOWS=false
    VNC_PORT=5900
    RDP_PORT=3389
    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    VIRTIO_ISO=""
    CREATED="$(date)"

    setup_vm_image
    save_vm_config
}

setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$VM_DIR"

    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image file already exists. Skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Failed to download image"
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi

    qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null || true

    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi

    print_status "SUCCESS" "VM '$VM_NAME' created successfully."
}

start_vm() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        if [[ "${IS_WINDOWS:-false}" == "true" ]]; then
            start_windows_vm "$vm_name"
            return
        fi

        print_status "INFO" "Starting VM: $vm_name"
        print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
        print_status "INFO" "Password: $PASSWORD"

        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "VM image file not found: $IMG_FILE"; return 1
        fi

        local qemu_cmd=(
            qemu-system-x86_64
            -m "$MEMORY"
            -smp "$CPUS"
            -cpu qemu64
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        )

        if [[ "$GUI_MODE" == true ]]; then
            qemu_cmd+=(-vga virtio -display gtk,gl=on)
        else
            qemu_cmd+=(-nographic -serial mon:stdio)
        fi

        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        "${qemu_cmd[@]}"
    fi
}

delete_vm() {
    local vm_name=$1
    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            rm -f "$IMG_FILE" "${SEED_FILE:-}" "$VM_DIR/$vm_name.conf" "$VM_DIR/$vm_name.pid" "$VM_DIR/$vm_name.installed" 2>/dev/null || true
            print_status "SUCCESS" "VM '$vm_name' has been deleted"
        fi
    else
        print_status "INFO" "Deletion cancelled"
    fi
}

show_vm_info() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "VM Information: $vm_name"
        echo "=========================================="
        echo "OS Type: ${IS_WINDOWS:-false} == true && echo Windows 11 || echo ${OS_TYPE:-Linux}"
        if [[ "${IS_WINDOWS:-false}" == "true" ]]; then
            echo "Type: Windows 11"
            echo "VNC Port: ${VNC_PORT:-5900}"
            echo "RDP Port: ${RDP_PORT:-3389}"
            echo "Browser: http://$(hostname -I | awk '{print $1}'):6080/vnc.html"
        else
            echo "OS: $OS_TYPE"
            echo "SSH Port: ${SSH_PORT:-2222}"
            echo "Username: ${USERNAME:-}"
            echo "Password: ${PASSWORD:-}"
        fi
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "Created: $CREATED"
        echo "=========================================="
        echo
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

is_vm_running() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then return 0; fi
    fi
    if pgrep -f "qemu-system-x86_64.*$vm_name" >/dev/null 2>&1; then return 0; fi
    return 1
}

stop_vm() {
    local vm_name=$1
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Stopping VM: $vm_name"
            local pid_file="$VM_DIR/$vm_name.pid"
            if [[ -f "$pid_file" ]]; then
                kill "$(cat "$pid_file")" 2>/dev/null || true
                rm -f "$pid_file"
            fi
            pkill -f "qemu-system-x86_64.*$IMG_FILE" 2>/dev/null || true
            fuser -k 6080/tcp 2>/dev/null || true
            print_status "SUCCESS" "VM $vm_name stopped"
        else
            print_status "INFO" "VM $vm_name is not running"
        fi
    fi
}

main_menu() {
    while true; do
        display_header

        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}

        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count existing VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if is_vm_running "${vms[$i]}"; then status="Running ✅"; fi
                local type="Linux"
                local conf="$VM_DIR/${vms[$i]}.conf"
                if grep -q 'IS_WINDOWS="true"' "$conf" 2>/dev/null; then type="Windows 11 🪟"; fi
                printf "  %2d) %s [%s] (%s)\n" $((i+1)) "${vms[$i]}" "$type" "$status"
            done
            echo
        fi

        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  6) Delete a VM"
        fi
        echo "  0) Exit"
        echo

        read -p "$(print_status "INPUT" "Enter your choice: ")" choice

        case $choice in
            1) create_new_vm ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to start: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}"
                    fi
                fi ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to stop: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                    fi
                fi ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show info: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    fi
                fi ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to delete: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    fi
                fi ;;
            0) print_status "INFO" "Goodbye!"; exit 0 ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac

        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

trap cleanup EXIT
check_dependencies

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

main_menu
