# WARP Proxy untuk Termux

Proxy lokal `127.0.0.1:9060` yang melewatkan trafic lewat **Cloudflare WARP** — IP egress milik Cloudflare sendiri. Berfungsi saat OpenCode diblokir gateway karena memakai proxy publik:

```
Error: Forbidden: request was blocked by a gateway or proxy
```

---

## Menu Interaktif (Default)

Jalankan `./warp.sh` tanpa argumen untuk membuka menu interaktif CLI:

```bash
./warp.sh
```

Tampilan Menu:
```
====================================================
         Cloudflare WARP Proxy Termux
====================================================
 Status: [ RUNNING ]

 [1] Cek Status & IP Publik
 [2] Restart Proxy (Ganti IP Egress)
 [3] Jalankan Proxy (Start)
 [4] Hentikan Proxy (Stop)
 [5] Setup / Install WARP Proxy
 [6] Registrasi Ulang Akun WARP Baru
 [7] Lihat Log Service (Realtime)
 [8] Jalankan Watchdog Auto-Restart
 [9] Tampilkan Command Export OpenCode
 [10] Uninstall WARP Proxy
 [0] Keluar

Pilih menu [0-10]:
```

---

## Instalasi

Cukup jalankan 1 baris perintah berikut di Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/raja-plenger/warp-proxy-termux/main/warp.sh | bash
```

Menangani: prasyarat, wireproxy (TUR), registrasi akun WARP, konfigurasi, dan setup runit (auto-restart + auto-start boot). Idempotent — jalankan ulang kapan saja.

> ⚠️ File configuration `~/.config/warp-proxy/wgcf-profile.conf` & `warp-account.json` berisi **private key akun WARP — jangan dibagikan**.

Perlu registrasi ulang (akun baru): hapus `~/.config/warp-proxy/wgcf-profile.conf` lalu jalankan `./warp.sh register` (atau `./warp.sh install`).

---

## Uninstalasi

```bash
./warp.sh uninstall [-y]
```

Menghentikan service dan watchdog, menghapus daemon `runit` (`$PREFIX/var/service/wireproxy`), serta memberikan opsi konfirmasi untuk membersihkan direktori konfigurasi (`~/.config/warp-proxy/`). Gunakan flag `-y` untuk otomatis mengonfirmasi pembersihan konfigurasi tanpa prompt interaktif (non-interaktif / scripting).

---

## Penggunaan Subcommand (Advanced / Scripting)

### Perintah Subcommand (`warp.sh`)

Selain menu interaktif, Anda dapat melempar subcommand secara langsung untuk scripting atau penggunaan cepat:

```bash
./warp.sh               # Membuka menu interaktif CLI (default)
./warp.sh start         # Nyalakan proxy
./warp.sh stop          # Hentikan proxy & watchdog
./warp.sh restart       # Restart proxy (dapatkan IP egress baru)
./warp.sh status        # Cek status proxy & IP publik (IPv4/IPv6)
./warp.sh logs          # Lihat log realtime service (tail -f)
./warp.sh watch         # Auto-restart bila mati (fallback manual)
./warp.sh register      # Registrasi ulang akun WARP
./warp.sh uninstall [-y] # Hentikan service, hapus runit daemon & (opsional) bersihkan config (-y untuk non-interaktif)
./warp.sh help          # Tampilkan pesan bantuan
```

Layanan diatur secara otomatis menggunakan `termux-services` (`runit`). Perintah `./warp.sh` mengontrol service `runit` jika tersedia, atau beralih ke mode manual jika diperlukan.

---

## Pakai dengan OpenCode

```bash
./warp.sh status   # pastikan jalan

# Copy-paste 1 baris untuk aktifkan proxy:
export HTTPS_PROXY=http://127.0.0.1:9060 HTTP_PROXY=http://127.0.0.1:9060 NO_PROXY=localhost,127.0.0.1 https_proxy=http://127.0.0.1:9060 http_proxy=http://127.0.0.1:9060 no_proxy=localhost,127.0.0.1

opencode
```

> `NO_PROXY` wajib — tanpanya TUI OpenCode kena routing loop (komunikasi server lokal ikut lewat proxy).

### Melepas proxy (berhenti pakai)

```bash
unset HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy
```

(untuk terminal baru cukup jangan export; untuk berhenti permanen di file `~/.bashrc`, hapus baris `export ...`-nya)

---

## Pengaturan Baterai & Background Resiliency (Android Doze Mode)

Agar proxy WARP dapat berjalan stabil di latar belakang tanpa terhenti oleh kebijakan manajemen daya Android (Doze Mode):

1. **Termux Wake Lock**:
   Secara otomatis `warp.sh` mengeksekusi `termux-wake-lock` saat proxy dinyalakan agar CPU Termux tidak masuk mode tidur (*sleep*). Saat proxy dihentikan via `./warp.sh stop`, lock ini akan dilepas (`termux-wake-unlock`).

2. **Nonaktifkan Optimasi Baterai Android**:
   Pastikan Termux tidak dibatasi oleh sistem Android:
   - Buka **Settings > Apps > Termux > Battery** (atau *Pengaturan Baterai*).
   - Pilih **Unrestricted** / **Jangan Dibatasi**.

3. **Kustomisasi Port Execution**:
   Secara default, proxy berjalan di port `9060`. Jika terjadi bentrok port, Anda dapat menjalankan proxy di port lain dengan environment variable `PORT`:
   ```bash
   PORT=9061 ./warp.sh start
   ```

---

## Struktur Penting

Source code script tersimpan di folder ini, sedangkan seluruh file konfigurasi, profil, dan log runtime tersimpan dengan aman di `~/.config/warp-proxy/`.

| Jalur / File | Fungsi |
|---|---|
| `warp.sh` | CLI tunggal terpadu (instalasi, registrasi, start, stop, restart, status, logs, watch, uninstall) |
| `~/.config/warp-proxy/wgcf-profile.conf` | Profil WireGuard WARP (rahasia) |
| `~/.config/warp-proxy/warp-account.json` | Detail akun WARP (rahasia) |
| `~/.config/warp-proxy/wireproxy.conf` | Listener HTTP `127.0.0.1:9060` (di-generate `warp.sh`) |
| `~/.config/warp-proxy/resolv.conf` | DNS workaround `/etc` read-only (di-generate `warp.sh`) |
| `~/.config/warp-proxy/ca-bundle.crt` | Sertifikat CA SSL |
| `~/.config/warp-proxy/warp.log` | Log aktivitas service proxy |
| `~/.config/warp-proxy/warp.pid` | PID proses wireproxy yang sedang berjalan |

Komponen: **wireproxy** (klien WireGuard user-mode jadi HTTP proxy) + **python (x25519)** (registrasi akun WARP) + **proot** (workaround DNS karena `/etc` read-only di Android).

---

## Troubleshooting

| Masalah | Solusi |
|---|---|
| Registrasi 403 | Tunggu beberapa menit (rate-limit WARP per IP), jalankan `./warp.sh register` atau `./warp.sh install` |
| Proxy tidak merespons | `./warp.sh restart` atau cek log dengan `./warp.sh logs` |
| Port 9060 dipakai | Hentikan dengan `./warp.sh stop` / ubah port di `~/.config/warp-proxy/wireproxy.conf` |
| OpenCode error proxy | Pastikan `NO_PROXY=localhost,127.0.0.1` diset |
| Ganti lokasi egress? | **Tidak bisa dipilih** — WARP mengikuti PoP terdekat; untuk region tertentu pakai VPS/proxy di negara target |

---

## Batasan

- Gratis, IP di ASN Cloudflare — lolos blokir gateway, tapi limit berbasis ASN tidak bisa dihindari
- IP bisa berulang & bergantian sendiri; jangan restart terlalu cepat
- Proyek eksperimental untuk uji coba; patuhi ToS layanan.
