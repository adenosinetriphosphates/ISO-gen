#!/usr/bin/env bash
set -euo pipefail

# ==========================
# FIXED CONFIG
# ==========================
UBUNTU_VERSION="24.04.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_INSTALL_SCRIPT="$SCRIPT_DIR/router-install.sh"

WORKDIR=""   # set after BUILD_DIR is known
REPORT=""

# ==========================
# DEFAULTS
# ==========================
ARCH=""
ISO_NAME=""
HOSTNAME=""
USERNAME=""
PASSWORD_PLAIN=""
BUILD_DIR="/router/build"
BOOT_LOGO_INPUT=""
YES_FLAG=0        # -y skips the confirmation prompt
INTERACTIVE=1     # set to 0 when all required flags are provided

# ==========================
# USAGE
# ==========================
usage() {
  cat <<USAGE
Usage: $0 [OPTIONS]

Flags (all optional — any omitted will be prompted interactively):
  -a, --arch      amd64|arm64        Architecture (default: amd64)
  -i, --iso       <name>             ISO/image name  (e.g. my-router)
  -H, --hostname  <hostname>         Hostname for installed system
  -u, --user      <username>         Admin username
  -p, --password  <password>         Admin password
  -d, --dir       <path>             Output directory for ISO/image
  -l, --logo      <file>             Boot logo file (PNG/BMP, relative to build.sh dir)
  -y, --yes                          Skip confirmation prompt
  --preset                           Shortcut: hostname=router, user=router,
                                     password=router, dir=/mnt/c/Users/arnav/Desktop,
                                     logo=logo.png (if it exists)
  -h, --help                         Show this help

Examples:
  # Fully interactive (prompts for everything):
  ./build.sh

  # Fully automated with your preset:
  ./build.sh --preset -i my-router -y

  # Manual flags:
  ./build.sh -a amd64 -i router-os -H router -u router -p router \
             -d /mnt/c/Users/arnav/Desktop -l logo.png -y

  # Mix flags + prompts (only omitted fields are prompted):
  ./build.sh -H myrouter -p secret
USAGE
  exit 0
}

# ==========================
# PARSE FLAGS
# ==========================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--arch)      ARCH="$2";          shift 2 ;;
    -i|--iso)       ISO_NAME="$2";      shift 2 ;;
    -H|--hostname)  HOSTNAME="$2";      shift 2 ;;
    -u|--user)      USERNAME="$2";      shift 2 ;;
    -p|--password)  PASSWORD_PLAIN="$2"; shift 2 ;;
    -d|--dir)       BUILD_DIR="$2";     shift 2 ;;
    -l|--logo)      BOOT_LOGO_INPUT="$2"; shift 2 ;;
    -y|--yes)       YES_FLAG=1;         shift ;;
    --preset)
      HOSTNAME="${HOSTNAME:-router}"
      USERNAME="${USERNAME:-router}"
      PASSWORD_PLAIN="${PASSWORD_PLAIN:-router}"
      BUILD_DIR="${BUILD_DIR:-/router/build}"
      BOOT_LOGO_INPUT="${BOOT_LOGO_INPUT:-logo.png}"
      shift ;;
    -h|--help)      usage ;;
    *) echo "[!] Unknown flag: $1"; usage ;;
  esac
done

# ==========================
# BANNER
# ==========================
echo ""
echo "┌─────────────────────────────────────┐"
echo "│        Router OS ISO Builder        │"
echo "└─────────────────────────────────────┘"
echo ""

# ==========================
# ARCH
# ==========================
if [ -z "$ARCH" ]; then
  echo "  [1] amd64  — standard x86-64 server / VM"
  echo "  [2] arm64  — Raspberry Pi (preinstalled image)"
  echo ""
  read -rp "Select architecture [1/2]: " ARCH_CHOICE
  case "$ARCH_CHOICE" in
    1) ARCH="amd64" ;;
    2) ARCH="arm64" ;;
    *) echo "[!] Invalid choice."; exit 1 ;;
  esac
else
  case "$ARCH" in
    amd64|arm64) ;;
    *) echo "[!] Invalid arch: $ARCH (must be amd64 or arm64)"; exit 1 ;;
  esac
  echo "  Architecture : $ARCH"
fi

echo ""

# ==========================
# PROMPT FOR ANYTHING MISSING
# ==========================
if [ -z "$ISO_NAME" ]; then
  read -rp "ISO name       (e.g. my-router): " ISO_NAME
  while [ -z "$ISO_NAME" ]; do
    echo "    ISO name cannot be empty."
    read -rp "ISO name       (e.g. my-router): " ISO_NAME
  done
fi

if [ -z "$HOSTNAME" ]; then
  read -rp "Hostname       (e.g. router):    " HOSTNAME
  while [ -z "$HOSTNAME" ]; do
    echo "    Hostname cannot be empty."
    read -rp "Hostname       (e.g. router):    " HOSTNAME
  done
fi

if [ -z "$USERNAME" ]; then
  read -rp "Admin username (e.g. router):    " USERNAME
  while [ -z "$USERNAME" ]; do
    echo "    Username cannot be empty."
    read -rp "Admin username (e.g. router):    " USERNAME
  done
fi

if [ -z "$PASSWORD_PLAIN" ]; then
  while true; do
    read -rsp "Password:                        " PASSWORD_PLAIN
    echo ""
    read -rsp "Confirm password:                " PASSWORD_CONFIRM
    echo ""
    if [ "$PASSWORD_PLAIN" = "$PASSWORD_CONFIRM" ]; then
      [ -n "$PASSWORD_PLAIN" ] && break
      echo "    Password cannot be empty."
    else
      echo "    Passwords do not match. Try again."
    fi
  done
fi

# ==========================
# DERIVED PATHS
# ==========================
WORKDIR="$BUILD_DIR/work"
REPORT="$BUILD_DIR/build_report.txt"
mkdir -p "$BUILD_DIR"

# ==========================
# OUTPUT PATH
# ==========================
if [ "$ARCH" = "amd64" ]; then
  ISO_OUT="$BUILD_DIR/${ISO_NAME}-${ARCH}.iso"
  [[ "$ISO_OUT" == *.iso ]] || ISO_OUT="${ISO_OUT}.iso"
  mkdir -p "$(dirname "$ISO_OUT")"
else
  IMG_OUT="$BUILD_DIR/${ISO_NAME}-${ARCH}.img"
  [[ "$IMG_OUT" == *.img ]] || IMG_OUT="${IMG_OUT}.img"
  mkdir -p "$(dirname "$IMG_OUT")"
fi

# ==========================
# BOOT LOGO
# Always embed a boot logo — either user-supplied or a generated black PNG.
# Prompt is shown for both amd64 and arm64; generation happens later in
# the arch-specific build block so WORKDIR is available.
# ==========================
BOOT_LOGO_SRC=""
BOOT_LOGO_DEST=""

if [ -z "$BOOT_LOGO_INPUT" ]; then
  echo ""
  echo "  Boot logo: place a PNG/BMP next to build.sh and enter its filename."
  echo "  Leave blank to auto-generate a black background."
  read -rp "Boot logo file (e.g. logo.png, blank to auto-generate): " BOOT_LOGO_INPUT
fi
if [ -n "$BOOT_LOGO_INPUT" ]; then
  BOOT_LOGO_SRC="$SCRIPT_DIR/$BOOT_LOGO_INPUT"
  if [ ! -f "$BOOT_LOGO_SRC" ]; then
    echo "    [!] Logo file not found: $BOOT_LOGO_SRC — will auto-generate black PNG."
    BOOT_LOGO_SRC=""
  else
    echo "    Logo found: $BOOT_LOGO_SRC"
  fi
fi
# NOTE: If BOOT_LOGO_SRC is still empty here, the build block will generate one.
# BOOT_LOGO_DEST is set inside the build block once WORKDIR is known.

# ==========================
# CONFIRM
# ==========================
echo ""
echo "┌─────────────────────────────────────┐"
echo "│             Build Config            │"
echo "└─────────────────────────────────────┘"
echo "  Arch     : $ARCH"
echo "  ISO name : $ISO_NAME"
echo "  Hostname : $HOSTNAME"
echo "  Username : $USERNAME"
echo "  Password : $(printf '%0.s*' $(seq 1 ${#PASSWORD_PLAIN}))"
if [ "$ARCH" = "amd64" ]; then
  echo "  Output   : $ISO_OUT"
else
  echo "  Output   : $IMG_OUT"
fi
if [ -n "$BOOT_LOGO_SRC" ]; then
  echo "  Boot logo: $BOOT_LOGO_SRC"
else
  echo "  Boot logo: (none)"
fi
echo ""
if [ "$YES_FLAG" -eq 0 ]; then
  read -rp "Looks good? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "[!] Aborted."
    exit 1
  fi
else
  echo "  (skipping confirmation — -y flag set)"
fi

# ==========================
# RESOLVE PATHS + URLS PER ARCH
# ==========================

if [ "$ARCH" = "amd64" ]; then
  BASE_IMAGE="$BUILD_DIR/base.iso"
  DOWNLOAD_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-${ARCH}.iso"
  MIN_SIZE_BYTES=629145600
else
  BASE_IMAGE="$BUILD_DIR/base.img.xz"
  DOWNLOAD_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-preinstalled-server-${ARCH}+raspi.img.xz"
  MIN_SIZE_BYTES=419430400
fi

# ==========================
# DOWNLOAD IF MISSING OR INCOMPLETE
# ==========================
needs_download() {
  local f="$1" min="$2"
  [ ! -f "$f" ] && return 0
  local size
  size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  [ "$size" -lt "$min" ] && return 0
  return 1
}

if needs_download "$BASE_IMAGE" "$MIN_SIZE_BYTES"; then
  rm -f "$BASE_IMAGE"
  echo ""
  echo "[+] Base image not found or incomplete: $BASE_IMAGE"
  echo "[+] Downloading: $DOWNLOAD_URL"
  echo "    (1-2 GB -- this will take a while)"
  echo ""
  if command -v wget >/dev/null 2>&1; then
    wget --show-progress --continue -O "$BASE_IMAGE" "$DOWNLOAD_URL"
  elif command -v curl >/dev/null 2>&1; then
    curl -L --progress-bar --continue-at - -o "$BASE_IMAGE" "$DOWNLOAD_URL"
  else
    echo "[!] Neither wget nor curl found. Install with: sudo apt install wget"
    echo "    Or manually place the image at: $BASE_IMAGE"
    exit 1
  fi
  echo ""
  if needs_download "$BASE_IMAGE" "$MIN_SIZE_BYTES"; then
    echo "[!] Download appears incomplete. Check network and retry."
    rm -f "$BASE_IMAGE"
    exit 1
  fi
  echo "[+] Download complete."
else
  SIZE_MB=$(( $(stat -c%s "$BASE_IMAGE") / 1024 / 1024 ))
  echo ""
  echo "[+] Found base image: $BASE_IMAGE (${SIZE_MB} MB)"
fi

# ==========================
# COMMON PRECHECKS
# ==========================
echo ""
echo "[+] Build started at $(date)" | tee "$REPORT"
echo "[+] Arch: $ARCH | ISO: $ISO_NAME | Host: $HOSTNAME | User: $USERNAME" | tee -a "$REPORT"

[ -f "$ROUTER_INSTALL_SCRIPT" ] || {
  echo "[!] router-install.sh not found at: $ROUTER_INSTALL_SCRIPT" | tee -a "$REPORT"
  echo "    It must be in the same directory as build.sh"
  exit 1
}

command -v openssl >/dev/null || { echo "[!] Missing: openssl (sudo apt install openssl)"; exit 1; }
PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD_PLAIN")

# ==========================
# PROGRESS BAR
# Reads 7z output line by line, counts "Path = " entries, draws a bar.
# ==========================
show_progress() {
  local total="$1"
  local count=0 pct=0 filled=0 bar=""
  while IFS= read -r line; do
    case "$line" in
      "Path = "*)
        (( count++ )) || true
        pct=$(( count * 100 / total ))
        [ "$pct" -gt 100 ] && pct=100
        filled=$(( pct / 2 ))
        bar=""
        for ((i=0; i<filled; i++));  do bar="${bar}█"; done
        for ((i=filled; i<50; i++)); do bar="${bar}░"; done
        printf "\r  [%s] %3d%% (%d/%d files)" "$bar" "$pct" "$count" "$total"
        ;;
      *[Ee][Rr][Rr][Oo][Rr]*)
        printf "\n[!] %s\n" "$line"
        ;;
    esac
  done
  bar=""
  for ((i=0; i<50; i++)); do bar="${bar}█"; done
  printf "\r  [%s] 100%% (%d/%d files)\n" "$bar" "$count" "$total"
}

# ==========================
# write_autoinstall()
# Writes a fully Subiquity-compliant autoinstall.yaml to the ISO root.
#
# KEY DECISIONS based on official Canonical docs:
#
# 1. File is named "autoinstall.yaml" and placed at the ISO root (/cdrom/).
#    Subiquity finds it there automatically — no nocloud datasource needed,
#    no #cloud-config header needed, no ds=nocloud kernel param issues.
#
# 2. The file starts directly with "autoinstall:" (no #cloud-config wrapper)
#    because it is NOT being delivered via cloud-init — it is on the media.
#
# 3. late-commands use "curtin in-target --" for commands that must run
#    inside the installed OS (chroot). Without this, commands run in the
#    installer environment where /target is mounted but not the active root.
#    router-install.sh writes to /target/* so it must run WITHOUT in-target.
#
# 4. No "user-data:" sub-key — that is not a valid autoinstall key and
#    causes a fatal schema validation error in Subiquity 24.x.
#
# 5. "shutdown: reboot" ensures automatic reboot after install completes —
#    no human needed to press enter.
#
# 6. "apt: fallback: offline-install" prevents the installer from dying
#    if there is no internet connection during installation.
#
# $1 = destination directory (ISO root workdir)
# ==========================
write_autoinstall() {
  local dest="$1"

  cat > "$dest/autoinstall.yaml" <<YAML
autoinstall:
  version: 1

  # Never pause for user input under any circumstance
  interactive-sections: []

  locale: en_US.UTF-8
  keyboard:
    layout: us

  identity:
    hostname: ${HOSTNAME}
    username: ${USERNAME}
    password: "${PASSWORD_HASH}"

  ssh:
    install-server: true
    allow-pw: true

  # Don't fail if there's no internet — the ISO has what we need
  apt:
    fallback: offline-install

  # Only install what we explicitly ask for
  packages:
    - openssh-server

  storage:
    layout:
      name: direct

  # late-commands run in the INSTALLER environment with /target mounted.
  # router-install.sh is a Subiquity installer-phase script that writes
  # config files into /target — so it must run here, NOT inside curtin in-target.
  # We copy it from /cdrom (the ISO) into /target/tmp so it survives.
  late-commands:
    - mkdir -p /target/tmp
    - cp /cdrom/router/router-install.sh /target/tmp/router-install.sh
    - chmod +x /target/tmp/router-install.sh
    - bash /target/tmp/router-install.sh
    - rm -f /target/tmp/router-install.sh


  # Automatically reboot when done — no human required
  shutdown: reboot
YAML
}

# ==========================
# VALIDATION HELPER
# ==========================
VALIDATION_FAILED=0
check() {
  local label="$1" condition="$2"
  if eval "$condition" >/dev/null 2>&1; then
    echo "  ✔ $label" | tee -a "$REPORT"
  else
    echo "  ✘ $label  <-- WILL CAUSE FAILURE" | tee -a "$REPORT"
    VALIDATION_FAILED=1
  fi
}

# ============================================================
# amd64 -- remaster live server ISO
# ============================================================
if [ "$ARCH" = "amd64" ]; then

  for cmd in xorriso 7z; do
    command -v "$cmd" >/dev/null || {
      echo "[!] Missing: $cmd  (sudo apt install xorriso p7zip-full)"
      exit 1
    }
  done

  # Count files so progress bar has an accurate total
  echo "[+] Counting files in ISO..." | tee -a "$REPORT"
  TOTAL_FILES=$(7z l "$BASE_IMAGE" 2>/dev/null | awk '/^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {count++} END {print count+0}')
  [ "$TOTAL_FILES" -eq 0 ] && TOTAL_FILES=1000
  echo "    $TOTAL_FILES files to extract." | tee -a "$REPORT"

  # Extract with progress bar
  echo "[+] Extracting ISO..." | tee -a "$REPORT"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  7z x "$BASE_IMAGE" -o"$WORKDIR" 2>&1 | show_progress "$TOTAL_FILES"
  echo "    Done." | tee -a "$REPORT"

  # Pull MBR + EFI boot blobs from the ORIGINAL ISO before we modify anything
  MBR_IMG="$BUILD_DIR/mbr.img"
  EFI_IMG="$BUILD_DIR/efi.img"

  echo "[+] Extracting MBR and EFI boot blobs..." | tee -a "$REPORT"
  dd if="$BASE_IMAGE" bs=1 count=432 of="$MBR_IMG" 2>/dev/null

  rm -f "$EFI_IMG"
  xorriso -osirrox on -indev "$BASE_IMAGE" \
    -extract /boot/grub/efi.img "$EFI_IMG" 2>/dev/null || true
  if [ ! -s "$EFI_IMG" ]; then
    xorriso -osirrox on -indev "$BASE_IMAGE" \
      -extract /EFI/boot/bootx64.efi "$EFI_IMG" 2>/dev/null || true
  fi

  # Embed router script + dashboard into ISO tree
  echo "[+] Embedding router-install.sh and dashboard..." | tee -a "$REPORT"
  mkdir -p "$WORKDIR/router"
  cp "$ROUTER_INSTALL_SCRIPT" "$WORKDIR/router/router-install.sh"
  chmod +x "$WORKDIR/router/router-install.sh"

  # Dashboard HTML — router-install.sh copies this to /usr/local/share/router-dashboard/
  DASHBOARD_HTML="$SCRIPT_DIR/router-dashboard.html"
  if [ -f "$DASHBOARD_HTML" ]; then
    cp "$DASHBOARD_HTML" "$WORKDIR/router/router-dashboard.html"
    echo "    Dashboard HTML embedded." | tee -a "$REPORT"
  else
    echo "    [!] router-dashboard.html not found at $DASHBOARD_HTML — dashboard will be missing" | tee -a "$REPORT"
  fi

  # Kernel logo — embed logo.png so firstboot can install it as the Linux
  # framebuffer logo (shown top-left during kernel boot, exactly like Tux).
  # Preference order: logo.png next to build.sh > the user-supplied boot logo > generated splash.
  KERNEL_LOGO_SRC=""
  if [ -f "$SCRIPT_DIR/logo.png" ]; then
    KERNEL_LOGO_SRC="$SCRIPT_DIR/logo.png"
  elif [ -n "$BOOT_LOGO_SRC" ] && [ "$BOOT_LOGO_SRC" != "__generated__" ] && [ -f "$BOOT_LOGO_SRC" ]; then
    KERNEL_LOGO_SRC="$BOOT_LOGO_SRC"
  else
    KERNEL_LOGO_SRC="$BOOT_LOGO_DEST"   # use the generated splash
  fi
  if [ -f "$KERNEL_LOGO_SRC" ]; then
    cp "$KERNEL_LOGO_SRC" "$WORKDIR/router/logo.png"
    echo "    Kernel logo embedded: $KERNEL_LOGO_SRC" | tee -a "$REPORT"
  fi

  # Write autoinstall.yaml to ISO root — Subiquity finds it automatically
  echo "[+] Writing autoinstall.yaml..." | tee -a "$REPORT"
  write_autoinstall "$WORKDIR"

  # ==========================
  # BOOT LOGO (optional)
  # Converts the user-supplied image to PNG (via ImageMagick if available,
  # otherwise copies as-is) and sets it as the GRUB background.
  # GRUB requires the image to be 640x480 or 1024x768 and named in the theme.
  # We write a minimal grub theme that just sets the background.
  # ==========================
  # ─────────────────────────────────────────────────────────────────────────────
  # Boot logo — ALWAYS embed. No logo supplied → generate black 1024x768 PNG.
  # GRUB requires: PNG, RGB (no alpha), non-interlaced, 1024x768 or 640x480.
  # We try ImageMagick, then Python Pillow, then raw copy.
  # The gfx block is injected into grub.cfg unconditionally so terminal_output
  # gfxterm always initialises (prevents garbled text even without a logo).
  #
  # Path notes:
  #   splash.png  → $WORKDIR/boot/grub/splash.png
  #   theme.txt   → $WORKDIR/boot/grub/theme/theme.txt
  #   desktop-image in theme.txt is RELATIVE to theme dir → "../splash.png"
  #   background_image in grub.cfg is an ABSOLUTE GRUB path → /boot/grub/splash.png
  # ─────────────────────────────────────────────────────────────────────────────
  mkdir -p "$WORKDIR/boot/grub"
  BOOT_LOGO_DEST="$WORKDIR/boot/grub/splash.png"

  if [ -n "$BOOT_LOGO_SRC" ]; then
    echo "[+] Embedding boot logo..." | tee -a "$REPORT"
    LOGO_OK=0

    # Method 1: ImageMagick — strips alpha, forces RGB, 1024x768, non-interlaced
    if command -v convert >/dev/null 2>&1; then
      convert "$BOOT_LOGO_SRC" \
        -resize 1024x768 -gravity center -background black -extent 1024x768 \
        -colorspace RGB -type TrueColor -interlace None \
        -define png:color-type=2 \
        "$BOOT_LOGO_DEST" 2>/dev/null && LOGO_OK=1
      [ "$LOGO_OK" -eq 1 ] \
        && echo "    Logo converted via ImageMagick (RGB 1024x768 non-interlaced)." | tee -a "$REPORT" \
        || echo "    [!] ImageMagick failed, trying Python Pillow..." | tee -a "$REPORT"
    fi

    # Method 2: Python Pillow
    if [ "$LOGO_OK" -eq 0 ] && python3 -c "import PIL" 2>/dev/null; then
      python3 - "$BOOT_LOGO_SRC" "$BOOT_LOGO_DEST" 2>/dev/null <<'PYLOGO' && LOGO_OK=1
import sys
from PIL import Image
img = Image.open(sys.argv[1]).convert("RGB")
img.thumbnail((1024, 768))
canvas = Image.new("RGB", (1024, 768), (0,0,0))
canvas.paste(img, ((1024-img.width)//2, (768-img.height)//2))
canvas.save(sys.argv[2], "PNG", interlace=False, optimize=False)
PYLOGO
      [ "$LOGO_OK" -eq 1 ] \
        && echo "    Logo converted via Python Pillow." | tee -a "$REPORT" \
        || echo "    [!] Python Pillow failed, copying raw." | tee -a "$REPORT"
    fi

    # Method 3: raw copy (last resort)
    if [ "$LOGO_OK" -eq 0 ] || [ ! -s "$BOOT_LOGO_DEST" ]; then
      cp "$BOOT_LOGO_SRC" "$BOOT_LOGO_DEST"
      echo "    Logo copied as-is (best effort — ensure RGB PNG 1024x768)." | tee -a "$REPORT"
    fi

  else
    # No logo supplied — generate a solid-black 1024x768 PNG via Python so
    # the GRUB gfx block still loads cleanly and gfxterm initialises.
    echo "[+] No boot logo supplied — generating black background PNG..." | tee -a "$REPORT"
    python3 - "$BOOT_LOGO_DEST" <<'PYBLACK' || true
import sys, struct, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
w, h = 1024, 768
scanline = b"\x00" + b"\x00" * (w * 3)
raw = scanline * h
comp = zlib.compress(raw, 9)
png = (b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", comp)
    + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PYBLACK
    echo "    Black background PNG generated." | tee -a "$REPORT"
    # Mark as present so patch_grub applies the gfx block
    BOOT_LOGO_SRC="__generated__"
  fi

  # Write GRUB theme (always written alongside splash.png)
  THEME_DIR="$WORKDIR/boot/grub/theme"
  mkdir -p "$THEME_DIR"
  cat > "$THEME_DIR/theme.txt" <<'THEME'
# RouterOS GRUB theme
title-text: ""
desktop-image: "../splash.png"
desktop-color: "#000000"
terminal-left: "0%"
terminal-top: "0%"
terminal-width: "100%"
terminal-height: "100%"
THEME
  echo "    Theme written." | tee -a "$REPORT"


  # Patch GRUB — both BIOS and EFI configs
  # FIX: replaced the buggy awk approach with a reliable sed one-liner.
  # The awk script's sub(/---\s*$/, ...) only fires when the line ends with ---,
  # which Ubuntu 24.04 grub.cfg lines may not, leaving the if(!/autoinstall/)
  # guard moot. sed with an address+condition is unambiguous.
  echo "[+] Patching GRUB configs..." | tee -a "$REPORT"
  patch_grub() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    cp "$cfg" "${cfg}.orig"
    # Zero the boot timeout so it goes straight to install
    sed -i 's/set timeout=.*/set timeout=0/' "$cfg"
    sed -i 's/set default=.*/set default=0/' "$cfg"
    # Append 'autoinstall' to any linux /casper/vmlinuz line that doesn't already have it
    sed -i '/^\s*linux\s.*casper\/vmlinuz/{ /autoinstall/! s/$/ autoinstall/ }' "$cfg"
    # Inject gfx + theme block for boot logo
    if [ -n "$BOOT_LOGO_SRC" ]; then
      # 1. Strip any existing gfx/theme lines to avoid duplicates
      sed -i '/^[[:space:]]*\(set gfxmode\|set gfxpayload\|insmod all_video\|insmod gfxterm\|insmod png\|terminal_output\|set theme=\|background_image\|load_video\)/d' "$cfg"
      # 2. Insert gfx block at the very top of the file (before anything else)
      #    This guarantees GRUB loads video drivers before any menuentry is parsed.
      local gfx_block
      gfx_block=$(cat <<'GFXBLOCK'
insmod all_video
insmod gfxterm
insmod png
set gfxmode=1024x768,auto
set gfxpayload=keep
terminal_output gfxterm
set theme=/boot/grub/theme/theme.txt
background_image /boot/grub/splash.png
GFXBLOCK
)
      # Prepend the block to the top of grub.cfg
      printf '%s\n%s\n' "$gfx_block" "$(cat "$cfg")" > "${cfg}.new" && mv "${cfg}.new" "$cfg"
    fi
  }
  patch_grub "$WORKDIR/boot/grub/grub.cfg"
  patch_grub "$WORKDIR/EFI/boot/grub.cfg"

  # Validate everything before spending time rebuilding the ISO
  echo "[+] Validating..." | tee -a "$REPORT"
  GRUB_CFG="$WORKDIR/boot/grub/grub.cfg"
  check "autoinstall param in grub.cfg"        "grep -q 'autoinstall' '$GRUB_CFG'"
  check "autoinstall.yaml at ISO root"          "[ -s '$WORKDIR/autoinstall.yaml' ]"
  check "autoinstall.yaml starts with autoinstall:" \
                                                "head -1 '$WORKDIR/autoinstall.yaml' | grep -q '^autoinstall:'"
  check "no #cloud-config in autoinstall.yaml" "! grep -q '#cloud-config' '$WORKDIR/autoinstall.yaml'"
  check "no invalid user-data: subkey"         "! grep -q '^  user-data:' '$WORKDIR/autoinstall.yaml'"
  check "shutdown: reboot present"              "grep -q 'shutdown: reboot' '$WORKDIR/autoinstall.yaml'"
  check "router-install.sh embedded"            "[ -x '$WORKDIR/router/router-install.sh' ]"
  check "late-commands copy script from cdrom"  "grep -q '/cdrom/router/router-install.sh' '$WORKDIR/autoinstall.yaml'"
  check "late-commands executes script"         "grep -q 'router-install.sh' '$WORKDIR/autoinstall.yaml'"
  if [ -n "$BOOT_LOGO_SRC" ]; then
    check "boot logo embedded"                  "[ -s '$BOOT_LOGO_DEST' ]"
    check "grub theme file present"             "[ -s '$WORKDIR/boot/grub/theme/theme.txt' ]"
  fi
  check "output directory writable"            "[ -w '$(dirname "$ISO_OUT")' ]"

  if [ "$VALIDATION_FAILED" -ne 0 ]; then
    echo "[!] Validation failed -- not building ISO." | tee -a "$REPORT"
    exit 1
  fi

  # Rebuild ISO
  echo "[+] Rebuilding ISO..." | tee -a "$REPORT"
  echo "    Output: $ISO_OUT" | tee -a "$REPORT"

  EFI_ARGS=()
  if [ -s "$EFI_IMG" ]; then
    EFI_ARGS=(
      -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$EFI_IMG"
      -appended_part_as_gpt
      -eltorito-alt-boot
      -e "--interval:appended_partition_2:::"
      -no-emul-boot
    )
    echo "  ✔ EFI found -- UEFI+BIOS hybrid" | tee -a "$REPORT"
  else
    echo "  ! No EFI image -- BIOS only" | tee -a "$REPORT"
  fi

  xorriso -as mkisofs \
    -r -V "$ISO_NAME" \
    -o "$ISO_OUT" \
    --grub2-mbr "$MBR_IMG" \
    -partition_offset 16 \
    --mbr-force-bootable \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot.catalog' \
    -b 'boot/grub/i386-pc/eltorito.img' \
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    "${EFI_ARGS[@]}" \
    "$WORKDIR"

  echo "" | tee -a "$REPORT"
  echo "[✔] ISO built: $ISO_OUT" | tee -a "$REPORT"
  echo ""
  echo "  Flash to USB : sudo dd if=$ISO_OUT of=/dev/sdX bs=4M status=progress && sync"
  echo "  Test in QEMU : qemu-system-x86_64 -m 2G -cdrom $ISO_OUT -boot d"
  echo ""

# ============================================================
# arm64 -- RPi preinstalled image
# ============================================================
else

  command -v xz >/dev/null || { echo "[!] Missing: xz (sudo apt install xz-utils)"; exit 1; }

  if [ "$EUID" -ne 0 ]; then
    echo "[!] arm64 requires root for loopback mount. Re-run with: sudo $0"
    exit 1
  fi

  IMG_RAW="$BUILD_DIR/base.img"
  if [ ! -f "$IMG_RAW" ] || [ "$(stat -c%s "$IMG_RAW")" -lt 1073741824 ]; then
    echo "[+] Decompressing .img.xz ..." | tee -a "$REPORT"
    rm -f "$IMG_RAW"
    xz --decompress --keep --stdout "$BASE_IMAGE" > "$IMG_RAW"
  else
    echo "[+] Found decompressed image: $IMG_RAW" | tee -a "$REPORT"
  fi

  echo "[+] Copying to output image..." | tee -a "$REPORT"
  cp "$IMG_RAW" "$IMG_OUT"

  LOOP_DEV=$(losetup -f)
  MNT_DIR="$BUILD_DIR/mnt"
  mkdir -p "$MNT_DIR"

  cleanup_mount() {
    umount "$MNT_DIR" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  }
  trap cleanup_mount EXIT

  echo "[+] Mounting system-boot (p1)..." | tee -a "$REPORT"
  losetup -P "$LOOP_DEV" "$IMG_OUT"
  mount "${LOOP_DEV}p1" "$MNT_DIR"

  # On RPi, system-boot is /boot/firmware at runtime
  # autoinstall.yaml goes there; script lives there too
  echo "[+] Embedding router-install.sh..." | tee -a "$REPORT"
  cp "$ROUTER_INSTALL_SCRIPT" "$MNT_DIR/router-install.sh"
  chmod +x "$MNT_DIR/router-install.sh"

  echo "[+] Writing autoinstall.yaml..." | tee -a "$REPORT"
  # For RPi, script is at /boot/firmware/router-install.sh at runtime
  cat > "$MNT_DIR/autoinstall.yaml" <<YAML
autoinstall:
  version: 1

  interactive-sections: []

  locale: en_US.UTF-8
  keyboard:
    layout: us

  identity:
    hostname: ${HOSTNAME}
    username: ${USERNAME}
    password: "${PASSWORD_HASH}"

  ssh:
    install-server: true
    allow-pw: true

  apt:
    fallback: offline-install

  packages:
    - openssh-server

  storage:
    layout:
      name: direct

  late-commands:
    - mkdir -p /target/tmp
    - cp /boot/firmware/router-install.sh /target/tmp/router-install.sh
    - chmod +x /target/tmp/router-install.sh
    - bash /target/tmp/router-install.sh
    - rm -f /target/tmp/router-install.sh


  shutdown: reboot
YAML

  # cloud-init still needs meta-data to exist (can be empty)
  touch "$MNT_DIR/meta-data"

  # ==========================
  # BOOT LOGO (arm64 / RPi)
  # U-Boot on RPi doesn't use GRUB splash, but we still embed the logo
  # into /boot/firmware so it can be used by firstboot scripts or Plymouth.
  # ==========================
  echo "[+] Embedding boot logo (arm64)..." | tee -a "$REPORT"
  BOOT_LOGO_DEST_ARM="$MNT_DIR/splash.png"
  LOGO_OK=0

  if [ -n "$BOOT_LOGO_SRC" ]; then
    # Method 1: ImageMagick
    if command -v convert >/dev/null 2>&1; then
      convert "$BOOT_LOGO_SRC"         -resize 1024x768 -gravity center -background black -extent 1024x768         -colorspace RGB -type TrueColor -interlace None         -define png:color-type=2         "$BOOT_LOGO_DEST_ARM" 2>/dev/null && LOGO_OK=1
    fi
    # Method 2: Python Pillow
    if [ "$LOGO_OK" -eq 0 ] && python3 -c "import PIL" 2>/dev/null; then
      python3 - "$BOOT_LOGO_SRC" "$BOOT_LOGO_DEST_ARM" 2>/dev/null <<'PYLOGO2' && LOGO_OK=1
import sys
from PIL import Image
img = Image.open(sys.argv[1]).convert("RGB")
img.thumbnail((1024, 768))
canvas = Image.new("RGB", (1024, 768), (0,0,0))
canvas.paste(img, ((1024-img.width)//2, (768-img.height)//2))
canvas.save(sys.argv[2], "PNG", interlace=False, optimize=False)
PYLOGO2
    fi
    # Method 3: raw copy
    if [ "$LOGO_OK" -eq 0 ]; then
      cp "$BOOT_LOGO_SRC" "$BOOT_LOGO_DEST_ARM"
      echo "    Logo copied as-is." | tee -a "$REPORT"
      LOGO_OK=1
    fi
  fi

  if [ "$LOGO_OK" -eq 0 ] || [ ! -s "$BOOT_LOGO_DEST_ARM" ]; then
    echo "[+] No logo supplied — generating ROUTER OS splash (arm64)..." | tee -a "$REPORT"
    python3 - "$BOOT_LOGO_DEST_ARM" <<'PYSPLASH2' || true
import sys, struct, zlib, os
OUT = sys.argv[1]; W, H = 1024, 768
def write_png(path, px, w, h):
    def chunk(t, d):
        return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    raw = b"".join(b"\x00"+bytes([c for p in row for c in p])
                   for row in [px[y*w:(y+1)*w] for y in range(h)])
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"
        +chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))
        +chunk(b"IDAT",zlib.compress(raw,6))+chunk(b"IEND",b""))
try:
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new("RGB",(W,H),(0,0,0)); draw = ImageDraw.Draw(img)
    fp = next((f for f in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"] if os.path.exists(f)), None)
    font = ImageFont.truetype(fp,120) if fp else ImageFont.load_default()
    text = "ROUTER OS"
    bb = draw.textbbox((0,0),text,font=font)
    tw,th = bb[2]-bb[0],bb[3]-bb[1]; x,y=(W-tw)//2,(H-th)//2-40
    for dx,dy in [(-4,4),(4,4),(0,5)]: draw.text((x+dx,y+dy),text,font=font,fill=(0,40,80))
    draw.text((x,y),text,font=font,fill=(0,180,255))
    img.save(OUT,"PNG")
except Exception:
    SCALE=13; FG=(0,180,255); BG=(0,0,0)
    G={"R":[0b11110,0b10001,0b10001,0b11110,0b10100,0b10010,0b10001],
       "O":[0b01110,0b10001,0b10001,0b10001,0b10001,0b10001,0b01110],
       "U":[0b10001,0b10001,0b10001,0b10001,0b10001,0b10001,0b01110],
       "T":[0b11111,0b00100,0b00100,0b00100,0b00100,0b00100,0b00100],
       "E":[0b11111,0b10000,0b10000,0b11110,0b10000,0b10000,0b11111],
       "S":[0b01111,0b10000,0b10000,0b01110,0b00001,0b00001,0b11110],
       " ":[0]*7}
    px=[BG]*(W*H); text="ROUTER OS"; cw=5*SCALE+4; tx=len(text)*cw-4
    sx=(W-tx)//2; sy=(H-7*SCALE)//2-20
    for i,ch in enumerate(text):
        rows=G.get(ch,G[" "])
        for r in range(7):
            b=rows[r]
            for c in range(5):
                col=FG if b&(1<<(4-c)) else BG
                for dy in range(SCALE):
                    for dx in range(SCALE):
                        ppx=sx+i*cw+c*SCALE+dx; ppy=sy+r*SCALE+dy
                        if 0<=ppx<W and 0<=ppy<H: px[ppy*W+ppx]=col
    write_png(OUT,px,W,H)
PYSPLASH2
    echo "    ROUTER OS splash generated (arm64)." | tee -a "$REPORT"
  fi

  echo "[+] Validating..." | tee -a "$REPORT"
  check "autoinstall.yaml present"              "[ -s '$MNT_DIR/autoinstall.yaml' ]"
  check "autoinstall.yaml starts correctly"     "head -1 '$MNT_DIR/autoinstall.yaml' | grep -q '^autoinstall:'"
  check "router-install.sh present"             "[ -f '$MNT_DIR/router-install.sh' ]"
  check "late-commands executes script"          "grep -q 'router-install.sh' '$MNT_DIR/autoinstall.yaml'"
  check "shutdown: reboot present"              "grep -q 'shutdown: reboot' '$MNT_DIR/autoinstall.yaml'"
  check "no #cloud-config header"               "! grep -q '#cloud-config' '$MNT_DIR/autoinstall.yaml'"
  check "output directory writable"            "[ -w '$(dirname "$IMG_OUT")' ]"

  if [ "$VALIDATION_FAILED" -ne 0 ]; then
    echo "[!] Validation failed -- aborting." | tee -a "$REPORT"
    exit 1
  fi

  cleanup_mount
  trap - EXIT

  echo "" | tee -a "$REPORT"
  echo "[✔] RPi image built: $IMG_OUT" | tee -a "$REPORT"
  echo ""
  echo "  Flash to SD : sudo dd if=$IMG_OUT of=/dev/sdX bs=4M status=progress && sync"
  echo "  SSH after first boot: ssh ${USERNAME}@<rpi-ip>"
  echo ""

fi

echo "[✔] Report: $REPORT"
