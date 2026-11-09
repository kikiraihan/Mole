#!/bin/bash
# Membuat macos-app/dist/install-MoleApp.command: installer satu file
# seperti pola install-LiteMonitor.command di kikiraihan/mac-os-lite-monitor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$MACOS_APP_DIR/dist"
OUT_FILE="$OUT_DIR/install-MoleApp.command"

mkdir -p "$OUT_DIR"

cat > "$OUT_FILE" << 'EOF'
#!/bin/bash
# ============================================================
#  Installer MoleApp (Menu Bar Indicator + Mac App Dashboard)
#  Jalankan:  bash install-MoleApp.command
#  Mengunduh rilis MoleApp.zip terbaru dari GitHub Releases
#  atau mengompilasi langsung dari source jika dibutuhkan.
# ============================================================
set -euo pipefail
clear
echo "=================================================="
echo "   Installer MoleApp (macOS Indicator & Cleaner)"
echo "=================================================="

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [[ "$MAJOR" -lt 13 ]]; then
    echo "❌ Butuh macOS 13 (Ventura) atau lebih baru. Versi Anda: $(sw_vers -productVersion)"
    read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."
    exit 1
fi

WORK=$(mktemp -d)
cleanup_work() {
    rm -rf "$WORK" # SAFE: removes only the mktemp working directory created above
}
trap cleanup_work EXIT
cd "$WORK"

APP="MoleApp.app"
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

echo "▶ Mengunduh MoleApp.zip terbaru dari GitHub Releases (kikiraihan/mole)..."
if curl -fsSL "https://github.com/kikiraihan/mole/releases/latest/download/MoleApp.zip" -o MoleApp.zip 2> /dev/null; then
    echo "▶ Mengekstrak MoleApp.app..."
    ditto -x -k MoleApp.zip .
else
    echo "⚠️  Unduhan langsung gagal, mengkloning & membangun dari repositori kikiraihan/mole..."
    git clone --depth=1 https://github.com/kikiraihan/mole.git repo
    cd repo
    ./macos-app/scripts/build.sh
    cp -R macos-app/build/MoleApp.app "$WORK/MoleApp.app"
    cd "$WORK"
fi

pkill -x MoleApp 2> /dev/null || true
if [[ -d "$DEST/$APP" ]]; then
    rm -rf "$DEST/$APP" # SAFE: removes previous MoleApp.app bundle before installing the new one
fi
cp -R "$APP" "$DEST/"
/usr/bin/xattr -cr "$DEST/$APP" 2> /dev/null || true

echo "▶ Menjalankan MoleApp..."
open "$DEST/$APP" --args --dashboard

echo ""
echo "✅ Selesai! MoleApp terpasang di: $DEST/$APP"
echo "   • Indikator sistem tampil di menu bar kanan atas (CPU, RAM, Disk, Quick Actions)."
echo "   • Klik kiri ikon untuk membuka Popover, atau klik 'Buka MoleApp Dashboard' untuk semua fitur Mole CLI."
echo "   • Klik kanan ikon untuk menu cepat & 'Buka saat Login'."
echo ""
read -n 1 -s -r -p "Tekan tombol apa saja untuk menutup jendela ini..."
EOF

chmod +x "$OUT_FILE"
echo "✅ $OUT_FILE"
