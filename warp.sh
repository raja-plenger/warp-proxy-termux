#!/data/data/com.termux/files/usr/bin/bash

# Cloudflare WARP proxy for Termux — Unified CLI
# SCRIPT_DIR resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/warp-proxy"
export CONFIG_DIR
mkdir -p "$CONFIG_DIR"

PORT="${PORT:-9060}"
CONF="$CONFIG_DIR/wireproxy.conf"
RESOLV="$CONFIG_DIR/resolv.conf"
LOG="$CONFIG_DIR/warp.log"
PIDFILE="$CONFIG_DIR/warp.pid"
WATCHDOG_PIDFILE="$CONFIG_DIR/warp-watchdog.pid"
SVC="wireproxy"
export SVDIR="${SVDIR:-$PREFIX/var/service}"
SVC_DIR="$SVDIR/$SVC"
export LOGDIR="${LOGDIR:-$PREFIX/var/log}"

migrate_old_configs() {
    for file in wgcf-profile.conf warp-account.json wireproxy.conf resolv.conf ca-bundle.crt warp.log warp.pid warp-watchdog.pid; do
        if [ -f "$SCRIPT_DIR/$file" ] && [ ! -f "$CONFIG_DIR/$file" ]; then
            mv "$SCRIPT_DIR/$file" "$CONFIG_DIR/$file" 2>/dev/null || true
        elif [ -f "$SCRIPT_DIR/$file" ] && [ -f "$CONFIG_DIR/$file" ]; then
            rm -f "$SCRIPT_DIR/$file" 2>/dev/null || true
        fi
    done
    if [ -f "$CONFIG_DIR/wireproxy.conf" ]; then
        cat > "$CONFIG_DIR/wireproxy.conf" <<EOF
WGConfig = "$CONFIG_DIR/wgcf-profile.conf"

[http]
BindAddress = "127.0.0.1:$PORT"
EOF
    fi
    chmod 600 "$CONFIG_DIR/wgcf-profile.conf" "$CONFIG_DIR/warp-account.json" 2>/dev/null || true
}
migrate_old_configs

is_running() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        return 0
    elif [ -S "$SVC_DIR/supervise/ok" ] && sv status "$SVC" 2>/dev/null | grep -q "^run:"; then
        return 0
    elif pgrep -x wireproxy > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_port_in_use() {
    python3 -c "import socket, sys; s = socket.socket(); s.settimeout(1); res = s.connect_ex(('127.0.0.1', $PORT)); s.close(); sys.exit(0 if res == 0 else 1)" 2>/dev/null
}

cmd_register() {
    if ! python3 -c "import cryptography" >/dev/null 2>&1; then
        echo "[!] Python3 atau python-cryptography belum terpasang. Jalankan ./warp.sh install terlebih dahulu."
        exit 1
    fi
    (
        set -e
        echo "=== Registrasi Akun Cloudflare WARP ==="
        python3 - << 'EOF'
import base64
import json
import os
import sys
import urllib.error
import urllib.request

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
except ImportError:
    print("[!] Module cryptography belum terinstall.", file=sys.stderr)
    sys.exit(1)

API = "https://api.cloudflareclient.com/v0a884/reg"
TOS = "2022-11-10T09:42:51.099Z"

priv = X25519PrivateKey.generate()
priv_raw = priv.private_bytes_raw()
pub_raw = priv.public_key().public_bytes_raw()

priv_b64 = base64.b64encode(priv_raw).decode()
pub_b64 = base64.b64encode(pub_raw).decode()

payload = json.dumps({
    "key": pub_b64,
    "tos": TOS,
    "type": "free",
    "locale": "en_US",
}).encode()

req = urllib.request.Request(
    API,
    data=payload,
    headers={
        "CF-Client-Version": "a-6.10-1910",
        "Content-Type": "application/json",
        "User-Agent": "okhttp/3.12.1",
    },
)

try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode())
except urllib.error.HTTPError as e:
    if e.code == 429:
        print("[!] Terkena rate-limit Cloudflare (HTTP 429). Mohon tunggu 5-10 menit atau ganti ke jaringan seluler/Wi-Fi.", file=sys.stderr)
    elif e.code == 403:
        print("[!] Registrasi diblokir Cloudflare (HTTP 403 WAF). Coba gunakan koneksi jaringan lain.", file=sys.stderr)
    else:
        print(f"[!] Gagal menghubungi API Cloudflare: HTTP Error {e.code} - {e.reason}", file=sys.stderr)
    sys.exit(1)
except urllib.error.URLError as e:
    print(f"[!] Gagal menghubungkan ke internet/API Cloudflare: {e.reason}", file=sys.stderr)
    sys.exit(1)

if "config" not in data and not data.get("success"):
    print(f"[!] Registrasi gagal: {data.get('errors')}", file=sys.stderr)
    sys.exit(1)

r = data.get("result", data)
config = r["config"]
peer = config["peers"][0]
addresses = config["interface"]["addresses"]

private_key = r.get("private_key", priv_b64)
v4_endpoint = peer['endpoint']['v4'].split(':')[0]

profile = f"""[Interface]
PrivateKey = {private_key}
Address = {addresses['v4']}, {addresses['v6']}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = {peer['public_key']}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {v4_endpoint}:2408
PersistentKeepalive = 25
"""

config_dir = os.environ.get("CONFIG_DIR", os.path.expanduser("~/.config/warp-proxy"))
profile_path = os.path.join(config_dir, "wgcf-profile.conf")
account_path = os.path.join(config_dir, "warp-account.json")

os.umask(0o077)
with open(profile_path, "w") as f:
    f.write(profile)

with open(account_path, "w") as f:
    json.dump(r, f, indent=2)

os.chmod(profile_path, 0o600)
os.chmod(account_path, 0o600)

print(f"[✓] Profile berhasil ditulis: {profile_path}")
print(f"[✓] Account ID: {r.get('id', 'N/A')}")
print(f"[✓] Endpoint v4: {v4_endpoint}:2408")
print(f"[✓] Addresses: {addresses['v4']}, {addresses['v6']}")
EOF
    )
}

cmd_install() {
    (
        set -e
        echo "=== [1/5] Memeriksa & menginstall prasyarat ==="
        for cmd in curl python3 proot pkg; do
            if ! command -v "$cmd" > /dev/null 2>&1; then
                echo "[*] Menginstall $cmd..."
                pkg install -y "$cmd"
            fi
        done

        if [ ! -f "$PREFIX/etc/apt/sources.list.d/tur.list" ]; then
            echo "[*] Menginstall tur-repo..."
            pkg install -y tur-repo
        fi

        if ! python3 -c "import cryptography" > /dev/null 2>&1; then
            echo "[*] Menginstall python-cryptography..."
            pkg install -y python-cryptography 2>/dev/null || python3 -m pip install cryptography || echo "[!] Gagal install cryptography"
        fi

        if ! command -v wireproxy > /dev/null 2>&1; then
            echo "[*] Menginstall wireproxy (dari TUR)..."
            pkg install -y wireproxy
        else
            echo "[✓] wireproxy sudah terpasang: $(wireproxy --version 2>&1 | head -1)"
        fi

        if ! command -v sv > /dev/null 2>&1; then
            echo "[*] Menginstall termux-services..."
            pkg install -y termux-services
        fi

        echo "=== [2/5] Menyiapkan DNS & CA certificates ==="
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$RESOLV"
        if [ ! -f "$CONFIG_DIR/ca-bundle.crt" ]; then
            cat /system/etc/security/cacerts/* > "$CONFIG_DIR/ca-bundle.crt" 2>/dev/null || true
        fi

        echo "=== [3/5] Registrasi Akun WARP ==="
        if [ -f "$CONFIG_DIR/wgcf-profile.conf" ]; then
            echo "[✓] wgcf-profile.conf sudah ada — lewati registrasi"
        else
            cmd_register
        fi

        echo "=== [4/5] Mengatur wireproxy & termux-services ==="
        if [ ! -f "$CONF" ]; then
            cat > "$CONF" <<EOF
WGConfig = "$CONFIG_DIR/wgcf-profile.conf"

[http]
BindAddress = "127.0.0.1:$PORT"
EOF
            echo "[✓] Konfigurasi wireproxy.conf dibuat"
        fi

        if ! pgrep -x runsvdir > /dev/null 2>&1; then
            echo "[*] Memulai daemon runsvdir..."
            service-daemon start 2>/dev/null || (nohup runsvdir "$PREFIX/var/service" > /dev/null 2>&1 & disown)
            sleep 2
        fi

        if pgrep -x wireproxy > /dev/null 2>&1; then
            if [ -f "$PIDFILE" ]; then
                kill "$(cat "$PIDFILE")" 2>/dev/null || true
                rm -f "$PIDFILE"
            else
                pkill -x wireproxy 2>/dev/null || true
            fi
            rm -f "$WATCHDOG_PIDFILE"
            sleep 1
        fi

        mkdir -p "$SVC_DIR/log"
        cat > "$SVC_DIR/run" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec proot -b "$RESOLV:/etc/resolv.conf" wireproxy -c "$CONF"
EOF
        cat > "$SVC_DIR/log/run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
pwd=${PWD%/*}
service=${pwd##*/}
mkdir -p "$LOGDIR/sv/$service"
exec svlogd -tt "$LOGDIR/sv/$service"
EOF
        chmod +x "$SVC_DIR/run" "$SVC_DIR/log/run"
        touch "$SVC_DIR/down"

        echo "[*] Menunggu runsv mengelola service $SVC..."
        for i in 1 2 3 4 5 6 7 8; do
            if [ -S "$SVC_DIR/supervise/ok" ]; then break; fi
            sleep 1
        done

        echo "[*] Mengaktifkan & menjalankan service $SVC..."
        sv-enable "$SVC" || echo "[!] sv-enable gagal — lanjut manual"
        sleep 2
        sv up "$SVC" 2>/dev/null || { echo "[!] sv up gagal — fallback manual"; cmd_start; }
        sleep 3

        echo "=== [5/5] Verifikasi ==="
        rm -f "$PIDFILE"
        if pgrep -x wireproxy > /dev/null 2>&1; then
            echo "[✓] Wireproxy berjalan (PID: $(pgrep -x wireproxy | head -1))"
        else
            echo "[!] Wireproxy tidak berjalan — cek: sv status $SVC"
        fi

        IP_INFO="$(curl -s -m 20 -x http://127.0.0.1:$PORT https://ip.pkgforge.dev/json 2>/dev/null)"
        if echo "$IP_INFO" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  IP publik:", d.get("ip"), "|", d.get("org"), "|", d.get("city"), d.get("country"))' 2>/dev/null; then
            echo "[✓] Verifikasi berhasil!"
        else
            echo "[!] Proxy belum merespons — tunggu sebentar lalu jalankan ./warp.sh status"
        fi

        echo ""
        echo "=== SELESAI ==="
        echo "Proxy WARP aktif di http://127.0.0.1:$PORT"
    )
}

cmd_start() {
    if is_running; then
        echo "[✓] Wireproxy sudah berjalan"
        return 0
    fi
    if check_port_in_use; then
        echo "[!] Port $PORT sudah terpakai oleh aplikasi lain! Gunakan PORT=9061 ./warp.sh start untuk port lain."
        return 1
    fi
    if command -v termux-wake-lock >/dev/null 2>&1; then
        termux-wake-lock 2>/dev/null || true
        echo "[✓] Android Wake-Lock diaktifkan (mencegah Termux di-freeze OS)"
    fi
    if [ ! -f "$CONFIG_DIR/wgcf-profile.conf" ]; then
        echo "[!] wgcf-profile.conf tidak ada. Jalankan ./warp.sh install dulu."
        return 1
    fi
    if [ ! -f "$RESOLV" ]; then
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$RESOLV"
    fi
    if [ ! -f "$CONF" ]; then
        cat > "$CONF" <<EOF
WGConfig = "$CONFIG_DIR/wgcf-profile.conf"

[http]
BindAddress = "127.0.0.1:$PORT"
EOF
    fi

    if [ -S "$SVC_DIR/supervise/ok" ]; then
        echo "[*] Memulai service via runit (sv up $SVC)..."
        sv up "$SVC" 2>/dev/null
        sleep 2
        if sv status "$SVC" 2>/dev/null | grep -q "^run:"; then
            echo "[✓] Service $SVC berhasil dijalankan via runit"
            return 0
        fi
    fi

    echo "[*] Memulai wireproxy secara manual (fallback)..."
    setsid nohup proot -b "$RESOLV:/etc/resolv.conf" wireproxy -c "$CONF" > "$LOG" 2>&1 &
    disown 2>/dev/null
    sleep 3
    if pgrep -x wireproxy > /dev/null 2>&1; then
        pgrep -x wireproxy | head -1 > "$PIDFILE"
        echo "[✓] Wireproxy WARP berjalan di http://127.0.0.1:$PORT (PID: $(cat "$PIDFILE"))"
    else
        echo "[!] Gagal start — cek $LOG"
        return 1
    fi
}

cmd_stop() {
    local stopped=0
    if [ -S "$SVC_DIR/supervise/ok" ]; then
        sv down "$SVC" 2>/dev/null && stopped=1
    fi
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE" && stopped=1
    fi
    if pgrep -x wireproxy > /dev/null 2>&1; then
        pkill -x wireproxy 2>/dev/null && stopped=1
    fi

    if [ $stopped -eq 1 ]; then
        echo "[✓] Wireproxy dihentikan"
    else
        echo "[!] Wireproxy tidak sedang berjalan"
    fi

    if [ -f "$WATCHDOG_PIDFILE" ]; then
        kill "$(cat "$WATCHDOG_PIDFILE")" 2>/dev/null || true
        rm -f "$WATCHDOG_PIDFILE"
        echo "[✓] Watchdog dihentikan"
    fi

    if command -v termux-wake-unlock >/dev/null 2>&1; then
        termux-wake-unlock 2>/dev/null || true
    fi
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    local v4 v6
    if [ -S "$SVC_DIR/supervise/ok" ] && sv status "$SVC" 2>/dev/null | grep -q "^run:"; then
        echo "[✓] Wireproxy berjalan (via runit $SVC)"
    elif [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "[✓] Wireproxy berjalan (manual, PID: $(cat "$PIDFILE"))"
    elif pgrep -x wireproxy > /dev/null 2>&1; then
        echo "[✓] Wireproxy berjalan (PID: $(pgrep -x wireproxy | head -1))"
    else
        echo "[✗] Wireproxy tidak berjalan"
        return 1
    fi

    v4="$(curl -4 -s -m 8 -x http://127.0.0.1:$PORT https://api.ipify.org 2>/dev/null)"
    v6="$(curl -6 -s -m 8 -x http://127.0.0.1:$PORT http://ipv6.icanhazip.com 2>/dev/null)"
    echo "    IPv4: ${v4:-? (tunnel idle)}"
    echo "    IPv6: ${v6:-? (tunnel idle)}"
}

cmd_logs() {
    if [ -f "$PREFIX/var/log/sv/$SVC/current" ]; then
        echo "[*] Menampilkan log runit ($PREFIX/var/log/sv/$SVC/current)..."
        tail -f "$PREFIX/var/log/sv/$SVC/current"
    elif [ -f "$LOG" ]; then
        echo "[*] Menampilkan log manual ($LOG)..."
        tail -f "$LOG"
    else
        echo "[!] Log tidak ditemukan"
    fi
}

cmd_watch() {
    if [ -f "$WATCHDOG_PIDFILE" ] && kill -0 "$(cat "$WATCHDOG_PIDFILE")" 2>/dev/null; then
        echo "[✓] Watchdog sudah berjalan (PID: $(cat "$WATCHDOG_PIDFILE"))"
        return 0
    fi
    local interval="${1:-60}"
    setsid nohup bash "$SCRIPT_DIR/warp.sh" loop "$interval" >> "$LOG" 2>&1 &
    disown 2>/dev/null
    for i in 1 2 3; do
        if [ -f "$WATCHDOG_PIDFILE" ] && kill -0 "$(cat "$WATCHDOG_PIDFILE")" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    if [ -f "$WATCHDOG_PIDFILE" ] && kill -0 "$(cat "$WATCHDOG_PIDFILE")" 2>/dev/null; then
        echo "[✓] Watchdog aktif (PID: $(cat "$WATCHDOG_PIDFILE"), interval ${interval}s)"
    else
        echo "[!] Watchdog gagal start"
        return 1
    fi
}

cmd_loop() {
    echo "$$" > "$WATCHDOG_PIDFILE"
    local interval="${1:-60}"
    if ! is_running; then
        cmd_start
    fi
    while true; do
        if ! is_running; then
            echo "[$(date +%H:%M:%S)] Wireproxy mati — restarting..." >> "$LOG"
            cmd_start
        fi
        sleep "$interval"
    done
}

cmd_uninstall() {
    local auto_yes=0
    if [ "$1" = "-y" ] || [ "$1" = "--yes" ]; then
        auto_yes=1
    fi
    echo "=== Uninstall WARP Proxy Termux ==="
    cmd_stop
    sv-disable "$SVC" 2>/dev/null || true
    sv down "$SVC" 2>/dev/null || true
    rm -rf "$SVC_DIR"
    rm -rf "$LOGDIR/sv/$SVC"
    echo "[✓] Service daemon runit ($SVC) berhasil dihapus."

    local confirm_purge=""
    if [ $auto_yes -eq 1 ]; then
        confirm_purge="y"
    else
        read -r -p "Hapus file konfigurasi & profil akun WARP (wgcf-profile.conf, wireproxy.conf, dll.)? [y/N]: " confirm_purge
    fi
    if [ "$confirm_purge" = "y" ] || [ "$confirm_purge" = "Y" ]; then
        rm -f "$CONFIG_DIR/wgcf-profile.conf" "$CONFIG_DIR/warp-account.json" "$CONFIG_DIR/wireproxy.conf" "$CONFIG_DIR/resolv.conf" "$CONFIG_DIR/ca-bundle.crt" "$CONFIG_DIR/warp.log" "$CONFIG_DIR/warp.pid" "$CONFIG_DIR/warp-watchdog.pid"
        rmdir "$CONFIG_DIR" 2>/dev/null || true
        echo "[✓] File konfigurasi & profil akun berhasil dibersihkan."
    else
        echo "[*] File profil & konfigurasi disimpan."
    fi
    echo "[✓] Uninstall selesai."
}

cmd_menu() {
    local CYAN='\033[1;36m'
    local GREEN='\033[1;32m'
    local RED='\033[1;31m'
    local YELLOW='\033[1;33m'
    local BLUE='\033[1;34m'
    local BOLD='\033[1m'
    local NC='\033[0m'

    while true; do
        clear 2>/dev/null || echo ""
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${BOLD}         Cloudflare WARP Proxy Termux${NC}"
        echo -e "${CYAN}====================================================${NC}"
        if is_running; then
            echo -e " Status: ${GREEN}[ RUNNING ]${NC}"
        else
            echo -e " Status: ${RED}[ STOPPED ]${NC}"
        fi
        echo ""
        echo -e " ${YELLOW}[1]${NC} Cek Status & IP Publik"
        echo -e " ${YELLOW}[2]${NC} Restart Proxy (Ganti IP Egress)"
        echo -e " ${YELLOW}[3]${NC} Jalankan Proxy (Start)"
        echo -e " ${YELLOW}[4]${NC} Hentikan Proxy (Stop)"
        echo -e " ${YELLOW}[5]${NC} Setup / Install WARP Proxy"
        echo -e " ${YELLOW}[6]${NC} Registrasi Ulang Akun WARP Baru"
        echo -e " ${YELLOW}[7]${NC} Lihat Log Service (Realtime)"
        echo -e " ${YELLOW}[8]${NC} Jalankan Watchdog Auto-Restart"
        echo -e " ${YELLOW}[9]${NC} Tampilkan Command Export OpenCode"
        echo -e " ${RED}[10]${NC} Uninstall WARP Proxy"
        echo -e " ${YELLOW}[0]${NC} Keluar"
        echo ""
        if ! read -r -p "Pilih menu [0-10]: " choice; then
            echo ""
            echo "[!] Terminal non-interaktif terdeteksi (EOF). Keluar."
            exit 0
        fi
        case "$choice" in
            1)
                echo ""
                cmd_status
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            2)
                echo ""
                cmd_restart
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            3)
                echo ""
                cmd_start
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            4)
                echo ""
                cmd_stop
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            5)
                echo ""
                cmd_install
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            6)
                echo ""
                cmd_register
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            7)
                echo ""
                cmd_logs
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            8)
                echo ""
                cmd_watch 60
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            9)
                echo ""
                echo -e "${CYAN}==================================================="
                echo -e "${BOLD}   Command Export Proxy (OpenCode & Terminal)${NC}"
                echo -e "${CYAN}===================================================${NC}"
                echo ""
                echo -e "${YELLOW}📌 Copy-Paste 1 Baris (Aktifkan Proxy):${NC}"
                echo "export HTTPS_PROXY=http://127.0.0.1:$PORT HTTP_PROXY=http://127.0.0.1:$PORT NO_PROXY=localhost,127.0.0.1 https_proxy=http://127.0.0.1:$PORT http_proxy=http://127.0.0.1:$PORT no_proxy=localhost,127.0.0.1"
                echo ""
                echo -e "${YELLOW}📌 Jalankan OpenCode:${NC}"
                echo "opencode"
                echo ""
                echo -e "${YELLOW}📌 Matikan / Lepas Proxy (Unset):${NC}"
                echo "unset HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy"
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            10)
                echo ""
                cmd_uninstall
                echo ""
                read -r -p "Tekan Enter untuk kembali ke menu..." || break
                ;;
            0)
                echo "Keluar."
                exit 0
                ;;
            *)
                echo "Pilihan tidak valid."
                sleep 1
                ;;
        esac
    done
}

cmd_help() {
    cat <<EOF
====================================================
         Cloudflare WARP Proxy Termux
====================================================
Usage: warp.sh <command> [args]

Subcommands:
  menu                   Jalankan menu interaktif CLI (default)
  install | setup        Instalasi lengkap (prasyarat, registrasi, service runit, test)
  uninstall [-y]          Hentikan service, hapus runit daemon & (opsional) bersihkan config
  register               Registrasi akun WARP & generate wgcf-profile.conf via Python
  start                  Jalankan proxy (runit atau manual fallback)
  stop                   Hentikan proxy dan watchdog
  restart                Restart proxy
  status                 Cek status service dan IP publik (IPv4/IPv6)
  logs                   Lihat log realtime service (tail -f)
  watch [interval]       Jalankan watchdog auto-restart (fallback jika tanpa runit)
  help | -h | --help     Tampilkan pesan bantuan ini

Cara Penggunaan & Eksplorasi:
  1. Unduh script ke Termux:
     curl -fsSL -O https://raw.githubusercontent.com/raja-plenger/warp-proxy-termux/main/warp.sh
     chmod +x warp.sh

  2. Jalankan Menu Interaktif CLI:
     ./warp.sh

  3. Atau jalankan Instalasi Langsung (1-Baris):
     curl -fsSL https://raw.githubusercontent.com/raja-plenger/warp-proxy-termux/main/warp.sh | bash -s install

Penggunaan dengan OpenCode (1 Baris Copy-Paste):
  export HTTPS_PROXY=http://127.0.0.1:$PORT HTTP_PROXY=http://127.0.0.1:$PORT NO_PROXY=localhost,127.0.0.1 https_proxy=http://127.0.0.1:$PORT http_proxy=http://127.0.0.1:$PORT no_proxy=localhost,127.0.0.1
  opencode
EOF
}

case "$1" in
    "")
        if [ -t 0 ]; then
            cmd_menu
        else
            cmd_help
        fi
        ;;
    menu)                cmd_menu ;;
    install|setup)       cmd_install ;;
    uninstall)           cmd_uninstall "$2" ;;
    register)            cmd_register ;;
    start)               cmd_start ;;
    stop)                cmd_stop ;;
    restart)             cmd_restart ;;
    status)              cmd_status ;;
    logs)                cmd_logs ;;
    watch)               cmd_watch "$2" ;;
    loop)                cmd_loop "$2" ;;
    help|-h|--help)      cmd_help ;;
    *)                   cmd_help; exit 1 ;;
esac
