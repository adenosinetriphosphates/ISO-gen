#!/usr/bin/env bash
# Subiquity late-command installer phase
# Runs OUTSIDE the installed system, with /target mounted.
# DO NOT run apt, systemctl, or anything that needs a live OS here.
# All we do here is write files into /target and set up the firstboot service.
set -euo pipefail

echo "[+] Router OS installer phase started"

LAN=eth1
ADMIN_VLAN=10
USER_VLAN=20
ADMIN_IP=192.168.10.1
USER_IP=192.168.20.1
WIFI_SSID_DEFAULT="RouterOS"
WIFI_PASS_DEFAULT="RouterOS"

# Auto-detect WAN interface: prefer eth0/ens* that has a default route or
# is the first physical ethernet that isn't eth1/ens34 (the LAN port).
# Falls back to eth0 if nothing can be detected (installer env may lack routes).
detect_wan() {
    # Try: interface currently holding the default route
    local via
    via=$(ip -4 route show default 2>/dev/null | awk '/^default/{print $5; exit}')
    [ -n "$via" ] && echo "$via" && return
    # Try: first UP ethernet that isn't the known LAN candidates
    local iface
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        case "$iface" in lo|wl*|br-*|vlan*) continue ;; esac
        ip link show "$iface" 2>/dev/null | grep -q "state UP" && echo "$iface" && return
    done
    # Fallback
    echo "eth0"
}
WAN=$(detect_wan)
echo "[+] WAN interface detected: $WAN"

# ============================================================
# SYSCTL
# ============================================================
cat >/target/etc/sysctl.d/99-router.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.${WAN}.rp_filter=2
net.ipv4.conf.vlan${ADMIN_VLAN}.rp_filter=1
net.ipv4.conf.vlan${USER_VLAN}.rp_filter=1
EOF

# ============================================================
# NETPLAN
#
# Architecture:
#   eth0  (WAN)  — DHCP from ISP
#   eth1  (LAN)  — trunk carrying VLAN 10 and VLAN 20
#   vlan10        — admin VLAN, 192.168.10.0/24
#   vlan20        — user VLAN,  192.168.20.0/24
#   br-admin      — Linux bridge on top of vlan10
#   br-user       — Linux bridge on top of vlan20
#
# WHY BRIDGES?
#   hostapd needs a *bridge* interface to bridge WiFi clients into a
#   wired segment. You cannot set bridge= to a raw VLAN interface
#   (vlan10/vlan20) — hostapd will exit with "bridge not found".
#   We create br-admin and br-user as bridges, put the VLANs in them,
#   then point hostapd at one of the bridges. WiFi clients then share
#   the same L2 segment and DHCP range as wired clients on that VLAN.
# ============================================================
mkdir -p /target/etc/netplan
# Netplan requires 600 permissions — without this it logs noisy warnings
cat >/target/etc/netplan/99-router.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN}:
      dhcp4: true
    ${LAN}:
      dhcp4: false
      optional: true
  vlans:
    vlan${ADMIN_VLAN}:
      id: ${ADMIN_VLAN}
      link: ${LAN}
    vlan${USER_VLAN}:
      id: ${USER_VLAN}
      link: ${LAN}
  bridges:
    br-admin:
      interfaces: [vlan${ADMIN_VLAN}]
      addresses: [${ADMIN_IP}/24]
      dhcp4: false
      parameters:
        stp: false
        forward-delay: 0
    br-user:
      interfaces: [vlan${USER_VLAN}]
      addresses: [${USER_IP}/24]
      dhcp4: false
      parameters:
        stp: false
        forward-delay: 0
EOF
chmod 600 /target/etc/netplan/99-router.yaml

# Tell networkd to leave ALL wlan* interfaces alone so hostapd owns them.
# Without this networkd grabs the WiFi card and blocks hostapd from using it.
mkdir -p /target/etc/systemd/network
cat >/target/etc/systemd/network/10-wifi-unmanaged.network <<EOF
[Match]
Name=wl*

[Link]
Unmanaged=yes
EOF

# ============================================================
# SYSTEMD UNITS (written into /target — run on the installed system)
# ============================================================

# --- Firstboot (runs once, disables itself) ---
cat >/target/etc/systemd/system/router-firstboot.service <<'EOF'
[Unit]
Description=Router First Boot Config
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/router-firstboot.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/router-firstboot.sh
ExecStartPost=/bin/systemctl disable router-firstboot.service
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

# --- Stats API (runs forever, feeds dashboard) ---
cat >/target/etc/systemd/system/router-stats-api.service <<'EOF'
[Unit]
Description=Router Stats API
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/router-stats-api.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# STATS API (Python — replaces broken bash+socat version)
# Pure stdlib, no dependencies. Serves GET /api/stats on 127.0.0.1:9191.
# Reads /proc and /sys directly — CPU, RAM, uptime, network bytes, services.
# ============================================================
mkdir -p /target/usr/local/sbin
cat >/target/usr/local/sbin/router-stats-api.py <<'STATSAPI'
#!/usr/bin/env python3
"""
router-stats-api.py
Replaces the broken bash+socat stats server.
Serves GET /api/stats as JSON on 127.0.0.1:9191.
All data read directly from /proc and /sys — no external deps.
"""
import json, os, time, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

def read(path, default="0"):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default

def detect_wan():
    try:
        out = subprocess.check_output(["ip", "-4", "route", "show", "default"], text=True)
        for line in out.splitlines():
            parts = line.split()
            if "via" in parts:
                return parts[parts.index("dev") + 1] if "dev" in parts else "eth0"
    except Exception:
        pass
    try:
        for name in sorted(os.listdir("/sys/class/net")):
            if name in ("lo",) or name.startswith(("br-", "vlan", "wl")):
                continue
            operstate = read(f"/sys/class/net/{name}/operstate", "down")
            if operstate == "up":
                return name
    except Exception:
        pass
    return "eth0"

def get_wifi_iface():
    try:
        out = subprocess.check_output(["iw", "dev"], text=True)
        for line in out.splitlines():
            if "Interface" in line:
                return line.split()[1]
    except Exception:
        pass
    try:
        for name in sorted(os.listdir("/sys/class/net")):
            if name.startswith("wl"):
                return name
    except Exception:
        pass
    return "none"

def get_vnstat(iface):
    try:
        out = subprocess.check_output(
            ["vnstat", "--json", "d", "30", "-i", iface],
            text=True, stderr=subprocess.DEVNULL, timeout=3
        )
        return json.loads(out)
    except Exception:
        return {}

def svc_status(name):
    try:
        out = subprocess.check_output(
            ["systemctl", "is-active", name],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
        return out
    except Exception:
        return "inactive"

def cpu_percent():
    """Sample /proc/stat twice 200ms apart and compute usage."""
    def read_cpu():
        line = read("/proc/stat", "cpu 0 0 0 0").splitlines()[0]
        vals = list(map(int, line.split()[1:5]))  # user nice system idle
        return vals
    s1 = read_cpu()
    time.sleep(0.2)
    s2 = read_cpu()
    total = sum(s2) - sum(s1)
    idle  = s2[3] - s1[3]
    return int(100 * (total - idle) / total) if total > 0 else 0

def get_dhcp_leases():
    leases = []
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 4:
                    leases.append({
                        "expires": int(parts[0]),
                        "mac":     parts[1],
                        "ip":      parts[2],
                        "host":    parts[3],
                    })
    except Exception:
        pass
    return leases

def get_stats():
    WAN = detect_wan()

    # Uptime
    uptime_sec = int(float(read("/proc/uptime").split()[0]))
    d, r = divmod(uptime_sec, 86400)
    h, r = divmod(r, 3600)
    m     = r // 60
    uptime_str = f"{d}d {h:02d}h {m:02d}m"

    # Load
    load = " ".join(read("/proc/loadavg").split()[:3])

    # Memory
    meminfo = {}
    for line in read("/proc/meminfo", "").splitlines():
        k, v = line.split(":", 1)
        meminfo[k.strip()] = int(v.strip().split()[0])
    mem_total = meminfo.get("MemTotal", 0)
    mem_used  = mem_total - meminfo.get("MemAvailable", 0)

    # CPU
    cpu_pct = cpu_percent()

    # Network bytes
    def net_bytes(iface):
        rx = int(read(f"/sys/class/net/{iface}/statistics/rx_bytes", "0"))
        tx = int(read(f"/sys/class/net/{iface}/statistics/tx_bytes", "0"))
        return rx, tx

    wan_rx, wan_tx       = net_bytes(WAN)
    admin_rx, admin_tx   = net_bytes("br-admin")
    user_rx, user_tx     = net_bytes("br-user")

    # WAN IP
    wan_ip = "unknown"
    try:
        out = subprocess.check_output(["ip", "-4", "addr", "show", WAN], text=True)
        for line in out.splitlines():
            if "inet " in line:
                wan_ip = line.strip().split()[1].split("/")[0]
                break
    except Exception:
        pass

    # WiFi
    wifi_iface  = get_wifi_iface()
    wifi_ssid   = "none"
    wifi_bridge = "none"
    try:
        with open("/etc/hostapd/hostapd.conf") as f:
            for line in f:
                if line.startswith("ssid="):
                    wifi_ssid = line.split("=", 1)[1].strip()
                elif line.startswith("bridge="):
                    wifi_bridge = line.split("=", 1)[1].strip()
    except Exception:
        pass

    return {
        "uptime":     uptime_str,
        "uptime_sec": uptime_sec,
        "load":       load,
        "cpu_pct":    cpu_pct,
        "memory":     {"total_kb": mem_total, "used_kb": mem_used},
        "wan":        {"interface": WAN,        "ip": wan_ip,        "rx_bytes": wan_rx,   "tx_bytes": wan_tx},
        "admin_vlan": {"interface": "br-admin", "ip": "192.168.10.1","rx_bytes": admin_rx, "tx_bytes": admin_tx},
        "user_vlan":  {"interface": "br-user",  "ip": "192.168.20.1","rx_bytes": user_rx,  "tx_bytes": user_tx},
        "wifi":       {"interface": wifi_iface, "ssid": wifi_ssid, "bridge": wifi_bridge},
        "services": {
            "nftables":    svc_status("nftables"),
            "dnsmasq":     svc_status("dnsmasq"),
            "wireguard":   svc_status("wg-quick@wg0"),
            "adguardhome": svc_status("AdGuardHome"),
            "ttyd":        svc_status("ttyd"),
            "nginx":       svc_status("nginx"),
            "hostapd":     svc_status("hostapd"),
            "vnstat":      svc_status("vnstat"),
        },
        "dhcp_leases": get_dhcp_leases(),
        "vnstat": {
            "wan":   get_vnstat(WAN),
            "admin": get_vnstat("br-admin"),
            "user":  get_vnstat("br-user"),
        },
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise in journal

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("/api/stats", ""):
            try:
                self.send_json(200, get_stats())
            except Exception as e:
                self.send_json(500, {"error": str(e)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_OPTIONS(self):
        self.send_json(200, {})

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 9191), Handler)
    print("[router-stats-api] Listening on 127.0.0.1:9191")
    server.serve_forever()
STATSAPI
chmod +x /target/usr/local/sbin/router-stats-api.py

# ============================================================
# WIFI CONFIG API (pure Python stdlib — no Flask needed)
# Listens on 127.0.0.1:8080 — nginx proxies /api/wifi/* here
# Handles: GET /api/wifi/status, POST /api/wifi/configure, POST /api/wifi/admin-password
# Runs as root via systemd — writes hostapd.conf and restarts hostapd directly.
#
# NOTE: Uses only http.server (stdlib) — Flask is NOT required and NOT installed.
#       The original import of python3-flask would fail on Ubuntu 24.04 without
#       universe enabled. Stdlib HTTPServer is identical in functionality here.
# ============================================================
cat >/target/usr/local/sbin/router-wifi-api.py <<'WIFIAPI'
#!/usr/bin/env python3
"""
Router WiFi Config API — stdlib only, no Flask dependency.
Bridges WiFi into either br-admin or br-user depending on VLAN choice.
"""
import json, os, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"
HOSTAPD_PASS = "/etc/hostapd/hostapd_pass"
BR_ADMIN     = "br-admin"
BR_USER      = "br-user"

def get_wifi_iface():
    try:
        out = subprocess.check_output(["iw", "dev"], text=True)
        for line in out.splitlines():
            if "Interface" in line:
                return line.split()[1]
    except Exception:
        pass
    try:
        for name in sorted(os.listdir("/sys/class/net")):
            if name.startswith("wl"):
                return name
    except Exception:
        pass
    return None

def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def read_hostapd():
    conf = {}
    try:
        with open(HOSTAPD_CONF) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    conf[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return conf

def write_hostapd(ssid, password, security, bridge):
    iface = get_wifi_iface()
    if not iface:
        raise RuntimeError("No WiFi interface found")
    key_mgmt   = "SAE"     if security == "wpa3" else "WPA-PSK"
    ieee80211w = "2"       if security == "wpa3" else "1"
    conf = (
        f"# RouterOS hostapd config — managed by router-wifi-api\n"
        f"interface={iface}\n"
        f"bridge={bridge}\n"
        f"driver=nl80211\n"
        f"ssid={ssid}\n"
        f"hw_mode=g\n"
        f"channel=6\n"
        f"ieee80211n=1\n"
        f"wmm_enabled=1\n"
        f"\n"
        f"# Security\n"
        f"wpa=2\n"
        f"wpa_passphrase={password}\n"
        f"wpa_key_mgmt={key_mgmt}\n"
        f"rsn_pairwise=CCMP\n"
        f"ieee80211w={ieee80211w}\n"
    )
    os.makedirs("/etc/hostapd", exist_ok=True)
    with open(HOSTAPD_CONF, "w") as f:
        f.write(conf)
    with open(HOSTAPD_PASS, "w") as f:
        f.write(password)
    os.chmod(HOSTAPD_PASS, 0o600)

def set_admin_password(new_password):
    escaped = new_password.replace("'", "'\\''")
    run(f"echo 'admin:{escaped}' | chpasswd")
    run("systemctl restart ttyd 2>/dev/null || true")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress access log

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_json(200, {})

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/wifi/status":
            iface = get_wifi_iface()
            conf  = read_hostapd()
            try:
                pw = open(HOSTAPD_PASS).read().strip()
            except Exception:
                pw = ""
            self.send_json(200, {
                "interface": iface or "none",
                "ssid":      conf.get("ssid", "RouterOS"),
                "security":  "wpa3" if conf.get("wpa_key_mgmt", "") == "SAE" else "wpa2",
                "bridge":    conf.get("bridge", BR_USER),
                "password":  pw,
                "active":    iface is not None,
            })
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        path   = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        raw    = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except Exception:
            self.send_json(400, {"error": "invalid JSON"})
            return

        if path == "/api/wifi/configure":
            ssid     = str(body.get("ssid", "RouterOS")).strip()[:32]
            password = str(body.get("password", "RouterOS")).strip()
            security = str(body.get("security", "wpa2")).lower()
            vlan     = str(body.get("vlan", "user"))
            bridge   = BR_ADMIN if vlan == "admin" else BR_USER

            errors = []
            if len(ssid) < 1:
                errors.append("SSID cannot be empty")
            if len(password) < 8:
                errors.append("Password must be at least 8 characters")
            if security not in ("wpa2", "wpa3"):
                errors.append("Security must be wpa2 or wpa3")
            if errors:
                self.send_json(400, {"error": "; ".join(errors)})
                return
            try:
                write_hostapd(ssid, password, security, bridge)
                run("systemctl restart hostapd")
                self.send_json(200, {
                    "ok": True,
                    "message": f"WiFi updated: SSID={ssid}, security={security.upper()}, bridge={bridge}"
                })
            except Exception as e:
                self.send_json(500, {"error": str(e)})

        elif path == "/api/wifi/admin-password":
            new_pw = str(body.get("password", "")).strip()
            if len(new_pw) < 8:
                self.send_json(400, {"error": "Password must be at least 8 characters"})
                return
            try:
                set_admin_password(new_pw)
                self.send_json(200, {"ok": True, "message": "Admin password updated"})
            except Exception as e:
                self.send_json(500, {"error": str(e)})
        else:
            self.send_json(404, {"error": "not found"})

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8080), Handler)
    print("[router-wifi-api] Listening on 127.0.0.1:8080")
    server.serve_forever()
WIFIAPI
chmod +x /target/usr/local/sbin/router-wifi-api.py

# ============================================================
# FIRSTBOOT SCRIPT
# Runs ONCE on first boot via router-firstboot.service.
# Has full network, apt, and systemctl access.
# Installs packages, writes runtime configs, starts services.
# ============================================================
cat >/target/usr/local/sbin/router-firstboot.sh <<'FIRSTBOOT'
#!/usr/bin/env bash
set -euo pipefail

LOGFILE=/var/log/router-firstboot.log
mkdir -p /var/log
touch "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1
export DEBIAN_FRONTEND=noninteractive

ADMIN_VLAN=10
USER_VLAN=20
ADMIN_IP=192.168.10.1
USER_IP=192.168.20.1
WIFI_SSID="RouterOS"
WIFI_PASS="RouterOS"

log()  { echo "[+] $*"; }
warn() { echo "[!] $* (continuing)" >&2; }

wait_for() {
    local label="$1" check="$2" timeout="${3:-60}"
    local elapsed=0
    log "Waiting for ${label}..."
    until eval "$check" &>/dev/null; do
        if [ "$elapsed" -ge "$timeout" ]; then
            warn "${label} not ready after ${timeout}s"
            return 1
        fi
        sleep 2; elapsed=$(( elapsed + 2 ))
    done
    log "${label} ready."
}

# Auto-detect WAN: interface with default route, or first UP non-LAN ethernet
detect_wan() {
    local via
    via=$(ip -4 route show default 2>/dev/null | awk '/^default/{print $5; exit}')
    [ -n "$via" ] && echo "$via" && return
    local iface
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        case "$iface" in lo|wl*|br-*|vlan*) continue ;; esac
        ip link show "$iface" 2>/dev/null | grep -q "state UP" && echo "$iface" && return
    done
    echo "eth0"
}

detect_wifi() {
    local iface
    iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1 || true)
    fi
    echo "${iface:-}"
}

log "============================================"
log " Router first boot — $(date)"
log "============================================"

# Detect WAN and LAN interfaces at runtime
WAN=$(detect_wan)
# LAN is the first ethernet that isn't WAN and isn't a bridge/vlan/wifi
LAN=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|en)' | grep -v "^${WAN}$" | head -1 || echo "eth1")
log "WAN interface : $WAN"
log "LAN interface : $LAN"


# ---------------------------
# Network — wait for WAN
# ---------------------------
systemctl start systemd-networkd || warn "systemd-networkd start failed"
wait_for "WAN route" "ip route get 1.1.1.1" 60 || true

# ---------------------------
# APT: enable universe, update, install
# universe is required for some packages (iw, hostapd, socat etc. are in main,
# but we enable it anyway to be safe for future additions).
# ---------------------------
log "Enabling universe repository..."
add-apt-repository -y universe 2>/dev/null || warn "add-apt-repository universe failed (may already be enabled)"

log "Installing packages..."
apt-get update -qq || warn "apt-get update failed"
apt-get install -y     nftables dnsmasq iproute2 sudo bridge-utils     nginx socat curl wget tar vnstat     hostapd iw wireless-tools rfkill     python3 python3-pil     || warn "Some packages failed to install"

# ---------------------------
# Kernel framebuffer logo (like Tux / Raspberry Pi logo)
# Converts logo.png to the PPM format the kernel expects, writes it into
# /lib/firmware/<kernel>/logo/ and rebuilds initramfs so it appears
# top-left on the console during every boot.
# ---------------------------
log "Installing kernel framebuffer logo..."
LOGO_SRC="/usr/local/share/router-dashboard/logo.png"
if [ -f "$LOGO_SRC" ]; then
    KVER=$(uname -r)
    LOGO_DIR="/lib/firmware/logo"
    mkdir -p "$LOGO_DIR"

    # Convert logo.png → 224-colour indexed PPM (kernel clut224 format)
    # The kernel logo must be ≤80×80 pixels, indexed to ≤224 colours, PPM P6 or P3.
    python3 - "$LOGO_SRC" "$LOGO_DIR/logo_linux_clut224.ppm" <<'PYLOGO' || warn "Logo conversion failed"
import sys
try:
    from PIL import Image
    img = Image.open(sys.argv[1]).convert("RGB")
    # Resize to fit kernel logo constraints (max 80x80, keep aspect)
    img.thumbnail((80, 80), Image.LANCZOS)
    # Quantize to 224 colours (kernel limit)
    img = img.quantize(colors=224).convert("RGB")
    w, h = img.size
    pixels = list(img.getdata())
    with open(sys.argv[2], "wb") as f:
        f.write(f"P6
{w} {h}
255
".encode())
        for r,g,b in pixels:
            f.write(bytes([r,g,b]))
    print(f"Logo written: {w}x{h} px")
except Exception as e:
    print(f"Logo conversion error: {e}", file=sys.stderr)
    sys.exit(1)
PYLOGO

    # Write the kernel logo C header that references our PPM
    # Ubuntu kernels ship LOGO support via CONFIG_LOGO — we override the
    # standard Tux by dropping our PPM into the firmware logo path and
    # patching /etc/default/grub to suppress the Tux and use our logo via
    # the bootsplash firmware mechanism (fbcon logo path).
    #
    # Simpler runtime approach: use the logo_linux_clut224 firmware slot.
    # Kernels with CONFIG_LOGO_LINUX_CLUT224 load from firmware if present.
    if [ -f "$LOGO_DIR/logo_linux_clut224.ppm" ]; then
        # Also copy as generic linux logo fallback
        cp "$LOGO_DIR/logo_linux_clut224.ppm" "$LOGO_DIR/logo_linux_mono.ppm" 2>/dev/null || true

        # Add kernel cmdline flag to show logo and suppress boot messages around it
        if [ -f /etc/default/grub ]; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="o.nologo=0 fbcon=logo-pos:0 quiet splash"/' /etc/default/grub
            # Remove duplicate quiet/splash if added multiple times
            sed -i 's/quiet splash quiet splash/quiet splash/g; s/logo\.nologo=0 logo\.nologo=0/logo.nologo=0/g' /etc/default/grub
            update-grub 2>/dev/null || warn "update-grub failed"
        fi

        update-initramfs -u -k all 2>/dev/null || warn "update-initramfs failed"
        log "Kernel logo installed (${KVER}) — will appear top-left on next boot."
    else
        warn "Logo PPM not created — kernel logo skipped."
    fi
else
    log "No logo.png found at $LOGO_SRC — skipping kernel logo."
fi

# ---------------------------
# Detect WiFi interface
# ---------------------------
WIFI_IFACE=$(detect_wifi)
if [ -z "$WIFI_IFACE" ]; then
    warn "No WiFi interface detected — hostapd will be configured but may not start"
    WIFI_IFACE="wlan0"
else
    log "WiFi interface detected: $WIFI_IFACE"
    rfkill unblock wifi 2>/dev/null || true
fi

# ---------------------------
# hostapd
# Bridge WiFi into br-user (user VLAN) by default.
# br-admin and br-user are created by netplan — they exist before this runs.
# hostapd's bridge= must point at a real Linux bridge, NOT a raw vlan interface.
# ---------------------------
log "Configuring hostapd..."
mkdir -p /etc/hostapd

if [ ! -f /etc/hostapd/.configured ]; then
    log "Writing default hostapd config (SSID: RouterOS / Pass: RouterOS, bridged to br-user)"
    cat >/etc/hostapd/hostapd.conf <<EOF
# RouterOS hostapd config
# Edit via web UI at http://192.168.10.1 or POST to /api/wifi/configure
interface=${WIFI_IFACE}
bridge=br-user
driver=nl80211
ssid=${WIFI_SSID}
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1

# WPA2-PSK
wpa=2
wpa_passphrase=${WIFI_PASS}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=1
EOF
    echo "${WIFI_PASS}" >/etc/hostapd/hostapd_pass
    chmod 600 /etc/hostapd/hostapd_pass
    touch /etc/hostapd/.configured
else
    log "hostapd already configured — keeping existing settings"
fi

echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >/etc/default/hostapd

# ---------------------------
# AdGuard Home
# ---------------------------
log "Installing AdGuard Home..."
AGH_DIR=/opt/AdGuardHome
AGH_VER=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4 2>/dev/null || echo "")
AGH_VER="${AGH_VER:-v0.107.43}"
AGH_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VER}/AdGuardHome_linux_amd64.tar.gz"

mkdir -p "$AGH_DIR"
# The archive structure changed across releases. Probe it before extracting.
AGH_TMP=$(mktemp -d)
curl -sL "$AGH_URL" | tar -xz -C "$AGH_TMP" 2>/dev/null || warn "AdGuard Home download failed"
# Find the binary wherever it landed
AGH_BIN=$(find "$AGH_TMP" -type f -name "AdGuardHome" | head -1)
if [ -n "$AGH_BIN" ]; then
    cp "$AGH_BIN" "$AGH_DIR/AdGuardHome"
    chmod +x "$AGH_DIR/AdGuardHome"
    log "AdGuard Home binary extracted OK"
else
    warn "AdGuard Home binary not found in archive"
fi
rm -rf "$AGH_TMP"

if [ -x "$AGH_DIR/AdGuardHome" ]; then
    # Note: schema_version omitted — AdGuardHome writes its own on first run
    cat >"$AGH_DIR/AdGuardHome.yaml" <<AGHCONF
http:
  address: 192.168.10.1:3000
  session_ttl: 720h
users:
  - name: admin
    password: \$2a\$10\$kHB/5g1yMBVVBvtDN.1x.O.lT4JOFNvl4UXFMJKB6Yqb7fKmE4Oi
dns:
  bind_hosts:
    - 192.168.10.1
    - 192.168.20.1
  port: 53
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  protection_enabled: true
  filtering_enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
AGHCONF
    # Write systemd unit directly instead of using -s install (which uses SysV
    # and conflicts with systemd on Ubuntu 24.04, causing the service to fail silently)
    cat >/etc/systemd/system/AdGuardHome.service <<'AGHUNIT'
[Unit]
Description=AdGuard Home DNS Ad Blocker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/AdGuardHome/AdGuardHome -s run
WorkingDirectory=/opt/AdGuardHome
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
AGHUNIT
    systemctl daemon-reload
    systemctl enable AdGuardHome || warn "AdGuard Home enable failed"
    systemctl start  AdGuardHome || warn "AdGuard Home start failed"
else
    warn "AdGuard Home binary not found — skipping"
fi

# ---------------------------
# ttyd — web terminal on admin VLAN only
# ---------------------------
log "Installing ttyd..."
TTYD_URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64"
curl -sL "$TTYD_URL" -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd \
    || warn "ttyd download failed"

if [ -x /usr/local/bin/ttyd ]; then
    cat >/etc/systemd/system/ttyd.service <<'TTYDUNIT'
[Unit]
Description=ttyd Web Terminal
After=network.target

[Service]
# Bind to all interfaces — nftables restricts access to br-admin only
ExecStart=/usr/local/bin/ttyd --port 7681 --credential admin:admin login
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
TTYDUNIT
    systemctl enable ttyd || warn "ttyd enable failed"
    systemctl start  ttyd || warn "ttyd start failed"
fi

# ---------------------------
# dnsmasq — DHCP only (port=0 disables DNS, AdGuard owns port 53)
# Listens on the bridge interfaces so WiFi clients (which land on br-user
# after hostapd bridges them in) also receive DHCP leases automatically.
# ---------------------------
log "Configuring dnsmasq..."
cat >/etc/dnsmasq.d/router.conf <<EOF
# DNS disabled — AdGuard Home handles port 53
port=0
no-resolv
bind-interfaces

# Listen on bridge interfaces (covers both wired VLAN ports AND WiFi clients)
interface=br-admin
interface=br-user

dhcp-range=interface:br-admin,192.168.10.50,192.168.10.150,12h
dhcp-option=interface:br-admin,option:router,${ADMIN_IP}
dhcp-option=interface:br-admin,option:dns-server,${ADMIN_IP}

dhcp-range=interface:br-user,192.168.20.50,192.168.20.150,12h
dhcp-option=interface:br-user,option:router,${USER_IP}
dhcp-option=interface:br-user,option:dns-server,${USER_IP}

dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF
mkdir -p /var/lib/misc

# ---------------------------
# vnstat — traffic history per interface
# ---------------------------
log "Configuring vnstat..."
for IFACE in ${WAN} br-admin br-user; do
    vnstat --add -i "$IFACE" 2>/dev/null || true
done
if [ -n "$WIFI_IFACE" ] && [ "$WIFI_IFACE" != "wlan0" ]; then
    vnstat --add -i "$WIFI_IFACE" 2>/dev/null || true
fi

# ---------------------------
# nftables
# Policy: WAN masquerade, admin VLAN has full access,
# user VLAN gets internet only (cannot reach admin VLAN).
# WiFi clients land on br-user and are treated identically to wired user clients.
#
# FIXED: port 8080 is NOT exposed externally — the wifi-api binds to
# 127.0.0.1:8080 only, so no nftables rule is needed for it.
# nginx on 192.168.10.1:80 proxies /api/wifi/ to 127.0.0.1:8080.
# ---------------------------
log "Configuring nftables..."
cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "${WAN}" masquerade
    }
}

table ip filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        ct state established,related accept

        # SSH — admin VLAN only
        iifname "br-admin" tcp dport 22 accept

        # DNS — both VLANs (AdGuard Home serves these)
        iifname { "br-admin", "br-user" } tcp dport 53 accept
        iifname { "br-admin", "br-user" } udp dport 53 accept

        # DHCP — both VLANs
        iifname { "br-admin", "br-user" } udp dport 67 accept

        # Web dashboard — admin VLAN only (nginx on port 80)
        iifname "br-admin" tcp dport 80 accept

        # AdGuard Home — admin VLAN only
        iifname "br-admin" tcp dport 3000 accept

        # ttyd terminal — admin VLAN only
        iifname "br-admin" tcp dport 7681 accept

        drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept

        # Both VLANs can reach the internet
        iifname "br-admin" oifname "${WAN}" accept
        iifname "br-user"  oifname "${WAN}" accept

        # User VLAN cannot reach admin VLAN
        iifname "br-user"  oifname "br-admin" drop

        drop
    }
}
EOF

# ---------------------------
# Apply netplan — bridges must exist before services start
# ---------------------------
log "Applying netplan..."
chmod 600 /etc/netplan/99-router.yaml 2>/dev/null || true
netplan apply || warn "netplan apply failed"
wait_for "br-admin" "ip link show br-admin" 30 || true
wait_for "br-user"  "ip link show br-user"  30 || true

# ---------------------------
# nginx — dashboard + API proxy
# /            → static dashboard
# /api/stats   → stats API (127.0.0.1:9191)
# /api/wifi/   → WiFi config API (127.0.0.1:8080)
# ---------------------------
log "Configuring nginx..."
cat >/etc/nginx/sites-available/router-dashboard <<'NGINXCONF'
server {
    # Listen on admin bridge IP (production) and loopback (testing/fallback)
    listen 192.168.10.1:80;
    listen 127.0.0.1:80;
    server_name _;
    root /var/www/router-dashboard;
    index index.html;

    location /api/stats {
        proxy_pass         http://127.0.0.1:9191;
        proxy_read_timeout 5s;
        proxy_connect_timeout 2s;
    }

    location /api/wifi/ {
        proxy_pass         http://127.0.0.1:8080;
        proxy_read_timeout 10s;
        proxy_connect_timeout 2s;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINXCONF
ln -sf /etc/nginx/sites-available/router-dashboard /etc/nginx/sites-enabled/router-dashboard
rm -f /etc/nginx/sites-enabled/default
mkdir -p /var/www/router-dashboard

if [ -f /usr/local/share/router-dashboard/index.html ]; then
    cp /usr/local/share/router-dashboard/index.html /var/www/router-dashboard/index.html
    log "Dashboard HTML installed."
else
    warn "Dashboard HTML not found at /usr/local/share/router-dashboard/index.html"
fi

# ---------------------------
# hostapd service override
# Waits for the WiFi interface AND the bridge to exist before hostapd starts.
# Without this hostapd races networkd and fails with "interface not found"
# or "bridge not found".
# ---------------------------
mkdir -p /etc/systemd/system/hostapd.service.d
cat >/etc/systemd/system/hostapd.service.d/router-override.conf <<'HOSTAPDOVERRIDE'
[Unit]
After=sys-subsystem-net-devices-wlan0.device systemd-networkd.service network-online.target
Wants=sys-subsystem-net-devices-wlan0.device network-online.target

[Service]
ExecStartPre=/bin/bash -c '\
    IFACE=$(grep "^interface=" /etc/hostapd/hostapd.conf | cut -d= -f2); \
    BRIDGE=$(grep "^bridge=" /etc/hostapd/hostapd.conf | cut -d= -f2); \
    for i in $(seq 1 20); do \
        ip link show "$IFACE" >/dev/null 2>&1 && \
        ip link show "$BRIDGE" >/dev/null 2>&1 && exit 0; \
        sleep 2; \
    done; \
    echo "hostapd: interface $IFACE or bridge $BRIDGE not ready"; exit 1'
RestartSec=5
Restart=on-failure
HOSTAPDOVERRIDE

# ---------------------------
# Enable + start all services
# ---------------------------
log "Enabling services..."
systemctl daemon-reload

for svc in nftables dnsmasq nginx router-stats-api router-wifi-api vnstat; do
    systemctl enable "$svc" 2>/dev/null || warn "$svc enable failed"
    systemctl restart "$svc" 2>/dev/null || warn "$svc restart failed"
done

systemctl daemon-reload

# Ubuntu 24.04 ships hostapd with a SysV init script at /etc/init.d/hostapd.
# When systemd tries to enable the unit, systemd-sysv-install runs and
# re-masks it because the SysV script conflicts. Fix: delete the SysV script
# so systemd manages hostapd purely via the systemd unit file.
rm -f /etc/init.d/hostapd
# Remove any stale mask symlink that may have been created
rm -f /lib/systemd/system/hostapd.service
systemctl unmask hostapd 2>/dev/null || true
systemctl daemon-reload
systemctl enable hostapd || warn "hostapd enable failed"
systemctl restart hostapd || warn "hostapd start failed — WiFi may need reboot"

# ---------------------------
# Router system user
# ---------------------------
log "Setting up router user..."
if ! id -u router >/dev/null 2>&1; then
    useradd -m -d /home/router -s /bin/bash router || warn "useradd failed"
fi
echo "router:router" | chpasswd || warn "chpasswd failed"
chown -R router:router /home/router

log "============================================"
log " First boot complete — $(date)"
log ""
log " WiFi SSID     : RouterOS"
log " WiFi Password : RouterOS (change at http://192.168.10.1)"
log " WiFi VLAN     : user (br-user / 192.168.20.0/24)"
log ""
log " Dashboard     : http://192.168.10.1"
log " WiFi Setup    : http://192.168.10.1/setup"
log " AdGuard Home  : http://192.168.10.1:3000"
log " Terminal      : http://192.168.10.1:7681"
log " SSH           : ssh router@192.168.10.1"
log "============================================"
FIRSTBOOT
chmod +x /target/usr/local/sbin/router-firstboot.sh

# ============================================================
# COPY DASHBOARD HTML FROM ISO TO TARGET
# This is the critical step that makes the dashboard available on first boot.
# The ISO embeds router-dashboard.html in /router/ (see build.sh).
# We copy it to /usr/local/share/router-dashboard/index.html in /target.
# router-firstboot.sh then copies it to /var/www/router-dashboard/index.html
# after nginx is configured.
# ============================================================
mkdir -p /target/usr/local/share/router-dashboard
if [ -f /cdrom/router/router-dashboard.html ]; then
    cp /cdrom/router/router-dashboard.html \
       /target/usr/local/share/router-dashboard/index.html
    echo "[+] Dashboard HTML copied from ISO to /target — OK"
else
    echo "[!] CRITICAL: router-dashboard.html not found at /cdrom/router/router-dashboard.html"
    echo "[!] The dashboard will show 404. Place router-dashboard.html next to build.sh before building."
fi

# Copy kernel logo from ISO to target for firstboot to install
if [ -f /cdrom/router/logo.png ]; then
    cp /cdrom/router/logo.png /target/usr/local/share/router-dashboard/logo.png
    echo "[+] Kernel logo copied from ISO to /target — OK"
fi

# ============================================================
# ENABLE SERVICES VIA SYMLINKS
# These symlinks tell systemd (in the installed system) to start these
# services at multi-user.target. Absolute paths work correctly because
# systemd resolves them relative to / after boot, not from /target.
# ============================================================
WANTS_DIR="/target/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS_DIR"
for svc in router-firstboot router-stats-api router-wifi-api; do
    ln -sf /etc/systemd/system/${svc}.service \
           "$WANTS_DIR/${svc}.service"
    echo "[+] Enabled: ${svc}.service"
done

echo "[✔] Installer phase complete"
