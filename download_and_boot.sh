#!/bin/bash
# ============================================================
# DESCARGADOR UNIVERSAL + QEMU BOOT v4.0
# Uso: ./download_and_boot.sh "URL" [RAM_MB]
# Soporta: Mediafire, Archive.org, Google Drive, enlaces directos
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

URL="${1:-}"
RAM_MB="${2:-4096}"
VNC_PORT=7
NOVNC_PORT=6081
WORKDIR="/content/qemu_work"
PIDFILE="/tmp/qemu_launcher.pids"

cleanup() {
    echo -e "\n${YELLOW}Limpiando procesos...${NC}"
    [[ -f "$PIDFILE" ]] && while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDFILE"
    pkill -f "qemu-system-x86_64" 2>/dev/null || true
    pkill -f "websockify" 2>/dev/null || true
    pkill -f "cloudflared" 2>/dev/null || true
    rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM

save_pid() { echo "$1" >> "$PIDFILE"; }
log() { local c="$1"; shift; echo -e "${c}[$(date +%H:%M:%S)]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
run() { "$@"; return $?; }

# ============================================================
# 1. DEPENDENCIAS
# ============================================================
instalar_deps() {
    log "$YELLOW" "🔧 Instalando dependencias..."

    # Limpiar sources.list problemáticos (Colab)
    rm -f /etc/apt/sources.list.d/*.list 2>/dev/null

    # Intentar apt-get update con reintento
    for i in 1 2 3; do
        if apt-get update -qq 2>/dev/null; then break; fi
        log "$YELLOW" "Reintento apt-get update $i/3..."
        sleep 3
    done

    # Instalar paquetes esenciales
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        qemu-system-x86 qemu-utils novnc websockify \
        p7zip-full unzip xz-utils bzip2 gzip curl wget bc \
        2>/dev/null || true

    # Verificar QEMU
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        err "QEMU no instalado. Intentando install manual..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-system-x86 qemu-utils 2>/dev/null || true
        if ! command -v qemu-system-x86_64 &>/dev/null; then
            err "QEMU sigue sin instalarse. Continuando de todos modos..."
        fi
    fi

    # Cloudflared
    if ! command -v cloudflared &>/dev/null; then
        log "$YELLOW" "Instalando cloudflared..."
        wget -q --no-check-certificate \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
            -O /tmp/cloudflared.deb 2>/dev/null && \
        dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || \
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
            -o /tmp/cloudflared.deb 2>/dev/null && \
        dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || \
        log "$YELLOW" "  cloudflared opcional"
    fi

    log "$GREEN" "Dependencias listas."
}

# ============================================================
# 2. RESOLVER URL
# ============================================================
resolver_url() {
    local url="$1"

    # Mediafire
    if [[ "$url" == *"mediafire.com"* ]]; then
        log "$CYAN" "Mediafire detectado"
        local dl
        dl=$(resolver_mediafire "$url")
        [[ -n "$dl" ]] && { echo "$dl"; return; }
    fi

    # Archive.org
    if [[ "$url" == *"archive.org"* ]]; then
        log "$CYAN" "Archive.org detectado"
        local dl
        dl=$(resolver_archive "$url")
        [[ -n "$dl" ]] && { echo "$dl"; return; }
    fi

    # Google Drive
    if [[ "$url" == *"drive.google.com"* ]]; then
        log "$CYAN" "Google Drive detectado"
        local dl
        dl=$(resolver_gdrive "$url")
        [[ -n "$dl" ]] && { echo "$dl"; return; }
    fi

    # Enlace directo por extensión
    if echo "$url" | grep -qiE '\.(iso|7z|vhd|vhdx|qcow2|img|vmdk|zip|tgz|tar\.gz|tar\.xz|tar\.bz2)(\?|$)'; then
        echo "$url"; return
    fi

    # Si contiene /download/ o /file/ o es github releases
    if [[ "$url" == */download/* || "$url" == *github.com/releases* ]]; then
        echo "$url"; return
    fi

    # Fallback: devolver la URL original
    echo "$url"
}

# --- Mediafire ---
resolver_mediafire() {
    local url="$1"
    local file_id

    file_id=$(echo "$url" | sed -n 's|.*/file/\([^/?]*\).*|\1|p')
    [[ -z "$file_id" ]] && file_id=$(echo "$url" | grep -oE '/[A-Za-z0-9]{15,}' | tr -d '/')

    [[ -z "$file_id" ]] && { err "  No se pudo extraer ID"; echo ""; return; }
    log "$CYAN" "  ID: $file_id"

    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
    local html
    html=$(curl -sL --max-time 20 -A "$ua" "https://www.mediafire.com/file/${file_id}/" 2>/dev/null)

    [[ -z "$html" ]] && { err "  No se pudo obtener la página"; echo ""; return; }

    # Múltiples patrones de extracción
    local direct
    direct=$(echo "$html" | grep -oE 'https?://download[0-9]+\.mediafire\.com[^"'"'"' <>]+' | head -1)

    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oE 'href="[^"]*download[^"]*mediafire[^"]*"' | sed 's/href="//;s/"//' | head -1)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oE '"url":"[^"]*mediafire[^"]*"' | sed 's/"url":"//;s/"//g;s/\\//g' | head -1)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oP 'downloadButton[^>]*href="\K[^"]+' | head -1)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oP 'aria-label="[Dd]ownload"[^>]*href="\K[^"]+' | head -1)

    if [[ -n "$direct" ]]; then
        log "$GREEN" "  Enlace extraído OK"
        echo "$direct"
    else
        err "  No se pudo extraer el enlace directo"
        echo ""
    fi
}

# --- Archive.org ---
resolver_archive() {
    local url="$1"
    local item_id

    item_id=$(echo "$url" | sed -n 's|.*/details/\([^/?#]*\).*|\1|p')
    [[ -z "$item_id" ]] && item_id=$(echo "$url" | sed -n 's|.*/download/\([^/?#]*\).*|\1|p')
    [[ -z "$item_id" ]] && { err "  No se pudo extraer ID"; echo ""; return; }

    log "$CYAN" "  Item: $item_id"

    # Intentar con API
    local metadata
    metadata=$(curl -sL --max-time 15 "https://archive.org/metadata/${item_id}" 2>/dev/null)

    if [[ -n "$metadata" ]]; then
        # Buscar archivos .iso, .img, .vhd, etc. usando Python si está disponible
        if command -v python3 &>/dev/null; then
            local best
            best=$(echo "$metadata" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    files = data.get('files', [])
    exts = ['iso', 'img', 'vhd', 'vhdx', 'qcow2', 'vmdk', '7z', 'zip', 'raw']
    best, best_size = None, 0
    for f in files:
        name = f.get('name', '')
        size = int(f.get('size', 0) or 0)
        for ext in exts:
            if name.lower().endswith('.' + ext):
                prio = 100 - exts.index(ext)
                score = size + prio * 10000000
                if score > best_size:
                    best, best_size = name, score
                break
    if best:
        print(best)
    else:
        for f in sorted(files, key=lambda x: int(x.get('size',0) or 0), reverse=True)[:3]:
            print(f['name'])
except: pass
" 2>/dev/null)
            if [[ -n "$best" ]]; then
                echo "https://archive.org/download/${item_id}/${best}"
                return
            fi
        fi
    fi

    # Fallback: parsear HTML de la página
    local page
    page=$(curl -sL --max-time 15 "https://archive.org/details/${item_id}" 2>/dev/null)
    if [[ -n "$page" ]]; then
        local links
        links=$(echo "$page" | grep -oE 'https://archive\.org/download/[^"'"'"' <>]+\.(iso|img|vhd|vhdx|qcow2|vmdk|7z|zip|raw)' | sort -u | head -1)
        if [[ -n "$links" ]]; then
            echo "$links"
            return
        fi
    fi

    err "  No se encontraron archivos descargables"
    echo ""
}

# --- Google Drive ---
resolver_gdrive() {
    local url="$1"
    local file_id

    file_id=$(echo "$url" | sed -n 's|.*/d/\([^/?#]*\).*|\1|p')
    [[ -z "$file_id" ]] && file_id=$(echo "$url" | sed -n 's|.*[?&]id=\([^&]*\).*|\1|p')
    [[ -z "$file_id" ]] && { err "  No se pudo extraer ID"; echo ""; return; }

    echo "https://drive.google.com/uc?export=download&id=${file_id}&confirm=t"
}

# ============================================================
# 3. NOMBRE DE ARCHIVO
# ============================================================
get_filename() {
    local url="$1"
    local filename

    # Intentar Content-Disposition
    if command -v curl &>/dev/null; then
        filename=$(curl -sI -L -A "Mozilla/5.0" "$url" 2>/dev/null | \
            grep -i "^content-disposition:" | sed 's/.*filename="\?//; s/"\?\s*$//; s/\r//' | tail -1)
    fi

    # Fallback: extraer de la URL
    if [[ -z "$filename" || "${#filename}" -lt 4 ]]; then
        filename=$(basename "$url" | sed 's/\?.*//')
        # Decodificar URL si python está disponible
        if command -v python3 &>/dev/null; then
            filename=$(python3 -c "
import urllib.parse, sys
try: print(urllib.parse.unquote('${filename}'))
except: print('${filename}')
" 2>/dev/null || echo "$filename")
        fi
    fi

    # Limpiar caracteres extraños
    filename=$(echo "$filename" | sed 's/[\/:*?"<>|]/-/g' | tr -d '[:cntrl:]')

    if [[ -z "$filename" || "${#filename}" -lt 5 ]]; then
        filename="downloaded_file.iso"
    fi

    echo "$filename"
}

# ============================================================
# 4. DESCARGA (ROBUSTA)
# ============================================================
descargar() {
    local url="$1"
    local filename="$2"

    log "$YELLOW" "Descargando: $(basename "$filename")"

    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
    local temp="${filename}.part"
    local success=0

    rm -f "$temp"

    # --- Google Drive con confirmación ---
    if [[ "$url" == *"drive.google.com/uc?export=download"* ]]; then
        log "$CYAN" "  Google Drive: manejando confirmación..."
        local cookie="/tmp/gdrive_cookie_$$.txt"
        rm -f "$cookie"
        curl -sc "$cookie" -L -A "$ua" "$url" > /dev/null 2>&1
        local confirm
        confirm=$(curl -sb "$cookie" -L -A "$ua" "$url" 2>/dev/null | grep -oP 'confirm=\K[a-zA-Z0-9_-]+' | head -1)
        [[ -n "$confirm" ]] && url="${url}&confirm=${confirm}"
        rm -f "$cookie"
    fi

    # --- 1. wget ---
    log "$CYAN" "  wget..."
    wget --timeout=30 --tries=5 --waitretry=10 --retry-connrefused \
         --continue --no-check-certificate --content-disposition \
         --user-agent="$ua" -O "$temp" "$url" > /dev/null 2>&1
    if [[ -f "$temp" && $(stat -c%s "$temp" 2>/dev/null || echo 0) -gt 500000 ]]; then
        mv "$temp" "$filename"; success=1
    else
        rm -f "$temp" 2>/dev/null
    fi

    # --- 2. curl ---
    if [[ "$success" -eq 0 ]]; then
        log "$YELLOW" "  wget falló, curl..."
        curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 --max-time 7200 \
             -C - -A "$ua" -o "$temp" "$url" > /dev/null 2>&1
        if [[ -f "$temp" && $(stat -c%s "$temp" 2>/dev/null || echo 0) -gt 500000 ]]; then
            mv "$temp" "$filename"; success=1
        else
            rm -f "$temp" 2>/dev/null
        fi
    fi

    # --- 3. requests Python ---
    if [[ "$success" -eq 0 ]] && command -v python3 &>/dev/null; then
        log "$YELLOW" "  curl falló, requests..."
        python3 -c "
import urllib.request, os, sys
ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36'
try:
    req = urllib.request.Request('${url}', headers={'User-Agent': ua})
    resp = urllib.request.urlopen(req, timeout=120)
    with open('${temp}', 'wb') as f:
        f.write(resp.read())
except Exception as e:
    sys.exit(1)
" 2>/dev/null
        if [[ -f "$temp" && $(stat -c%s "$temp" 2>/dev/null || echo 0) -gt 500000 ]]; then
            mv "$temp" "$filename"; success=1
        else
            rm -f "$temp" 2>/dev/null
        fi
    fi

    # --- Verificar ---
    if [[ "$success" -eq 1 ]]; then
        local size
        size=$(stat -c%s "$filename" 2>/dev/null || echo 0)
        local size_mb=$((size / 1048576))
        log "$GREEN" "  Descargado: ${size_mb} MB"
        return 0
    fi

    err "  Falló la descarga después de 3 intentos"
    return 1
}

# ============================================================
# 5. EXTRACCIÓN
# ============================================================
extraer_si_necesario() {
    local archivo="$1"
    local dir="$2"
    mkdir -p "$dir"

    local ext
    ext=$(echo "$archivo" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        *.7z)
            log "$YELLOW" "Extrayendo 7z..."
            7z x -y -o"$dir" "$archivo" > /dev/null 2>&1 || err "  Error 7z"
            for f in "$dir"/*.7z; do
                [[ -f "$f" ]] && 7z x -y -o"$dir" "$f" > /dev/null 2>&1 || true
            done
            ;;
        *.zip)
            log "$YELLOW" "Extrayendo ZIP..."
            unzip -o -q "$archivo" -d "$dir" > /dev/null 2>&1 || err "  Error ZIP"
            ;;
        *.tar.gz|*.tgz)
            log "$YELLOW" "Extrayendo TAR.GZ..."
            tar -xzf "$archivo" -C "$dir" > /dev/null 2>&1 || err "  Error TAR.GZ"
            ;;
        *.tar.xz|*.txz)
            log "$YELLOW" "Extrayendo TAR.XZ..."
            tar -xJf "$archivo" -C "$dir" > /dev/null 2>&1 || err "  Error TAR.XZ"
            ;;
        *.tar.bz2|*.tbz2)
            log "$YELLOW" "Extrayendo TAR.BZ2..."
            tar -xjf "$archivo" -C "$dir" > /dev/null 2>&1 || err "  Error TAR.BZ2"
            ;;
        *.xz)
            log "$YELLOW" "Descomprimiendo XZ..."
            xz -dk "$archivo" --stdout > "${dir}/$(basename "$archivo" .xz)" 2>/dev/null || err "  Error XZ"
            ;;
        *.bz2)
            log "$YELLOW" "Descomprimiendo BZ2..."
            bzip2 -dk "$archivo" --stdout > "${dir}/$(basename "$archivo" .bz2)" 2>/dev/null || err "  Error BZ2"
            ;;
        *.iso|*.vhd|*.vhdx|*.qcow2|*.img|*.vmdk|*.raw)
            log "$GREEN" "Imagen: $(basename "$archivo")"
            cp "$archivo" "$dir/"
            ;;
        *)
            log "$YELLOW" "Copiando: $(basename "$archivo")"
            cp "$archivo" "$dir/"
            ;;
    esac
}

# ============================================================
# 6. BUSCAR IMAGEN BOOTEABLE
# ============================================================
buscar_imagen() {
    local dir="$1"
    local best=""
    local best_size=0

    log "$YELLOW" "Buscando imagen booteable..."

    for ext in vhd vhdx img qcow2 vmdk raw iso; do
        find "$dir" -maxdepth 3 -type f -iname "*.${ext}" 2>/dev/null | while IFS= read -r f; do
            local size
            size=$(stat -c%s "$f" 2>/dev/null || echo 0)
            local size_mb=$((size / 1048576))
            if [[ "$size_mb" -gt 50 ]]; then
                echo "$f:$size:$ext"
            fi
        done
    done | sort -t: -k2 -rn | while IFS=: read -r f size ext; do
        local size_mb=$((size / 1048576))
        log "$CYAN" "  $(basename "$f") (${size_mb} MB)"
        local priority=0
        [[ "$ext" == "iso" ]] && priority=10000000000
        local total=$((size + priority))
        echo "$total:$f"
    done | sort -t: -k1 -rn | head -1 | cut -d: -f2-
}

# ============================================================
# 7. QEMU
# ============================================================
iniciar_qemu() {
    local imagen="$1"
    local ext
    ext=$(echo "${imagen##*.}" | tr '[:upper:]' '[:lower:]')

    local format="raw" media="disk" boot="c"
    case "$ext" in
        vhd|vpc)  format="vpc" ;;
        vhdx)     format="vhdx" ;;
        qcow2)    format="qcow2" ;;
        img|raw)  format="raw" ;;
        iso)      format="raw"; media="cdrom"; boot="d" ;;
        vmdk)     format="vmdk" ;;
    esac

    log "$YELLOW" "Iniciando QEMU (${RAM_MB} MB, formato: ${format})..."

    # Matar previos
    pkill -f "qemu-system-x86_64" 2>/dev/null || true
    sleep 2

    # Puerto VNC
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        VNC_PORT=$((VNC_PORT + 1))
    fi

    # Aceleración
    local accel="tcg,thread=multi"
    [[ -e /dev/kvm ]] && accel="kvm"

    # CPUs
    local cpus
    cpus=$(nproc 2>/dev/null || echo 2)
    [[ "$cpus" -gt 4 ]] && cpus=4

    local args=(-m "$RAM_MB" -smp "$cpus" -cpu max
                -accel "$accel" -machine type=pc
                -vga std -display vnc=:$VNC_PORT
                -usb -device usb-tablet -rtc base=localtime
                -netdev user,id=net0 -device e1000,netdev=net0)

    if [[ "$media" == "cdrom" ]]; then
        local disk_img="/content/qemu_disk.qcow2"
        if [[ ! -f "$disk_img" ]]; then
            qemu-img create -f qcow2 "$disk_img" 60G > /dev/null 2>&1
        fi
        qemu-system-x86_64 "${args[@]}" \
            -drive file="$disk_img",format=qcow2,index=0,media=disk \
            -drive file="$imagen",format=raw,index=1,media=cdrom -boot d \
            > /dev/null 2>&1 &
        save_pid $!
    else
        qemu-system-x86_64 "${args[@]}" \
            -drive file="$imagen",format="$format",if=ide,index=0 -boot c \
            > /dev/null 2>&1 &
        save_pid $!
    fi

    local pid=$!
    for i in $(seq 1 12); do
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
                log "$GREEN" "QEMU corriendo (VNC puerto $VNC_PORT)"
                return 0
            fi
        fi
    done

    err "QEMU no respondió"
    return 1
}

# ============================================================
# 8. TUNEL
# ============================================================
iniciar_remoto() {
    log "$YELLOW" "Iniciando noVNC + túnel..."

    # noVNC
    local novnc_dir=""
    for d in "/usr/share/novnc" "/usr/share/noVNC" "/usr/local/share/novnc" "/tmp/noVNC"; do
        [[ -d "$d" ]] && { novnc_dir="$d"; break; }
    done

    if [[ -z "$novnc_dir" ]]; then
        log "$YELLOW" "  Descargando noVNC..."
        novnc_dir="/tmp/noVNC"
        git clone --depth 1 https://github.com/novnc/noVNC.git "$novnc_dir" > /dev/null 2>&1 || true
        [[ -d "$novnc_dir" ]] || novnc_dir=""
    fi

    if [[ -d "$novnc_dir" ]]; then
        websockify --web "$novnc_dir" "$NOVNC_PORT" "localhost:590${VNC_PORT}" > /dev/null 2>&1 &
        save_pid $!
        sleep 2
        log "$GREEN" "  noVNC: http://127.0.0.1:${NOVNC_PORT}"
    fi

    # Túnel
    local tunnel_url=""
    if command -v cloudflared &>/dev/null; then
        log "$CYAN" "  Cloudflare..."
        cloudflared tunnel --no-autoupdate \
            --url "http://127.0.0.1:${NOVNC_PORT}" > /tmp/cloudflared.log 2>&1 &
        save_pid $!
        for i in $(seq 1 30); do
            tunnel_url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
            [[ -n "$tunnel_url" ]] && break
            sleep 2
        done
    fi

    if [[ -z "$tunnel_url" ]] && command -v ngrok &>/dev/null; then
        log "$CYAN" "  ngrok..."
        ngrok http "$NOVNC_PORT" --log=stdout > /tmp/ngrok.log 2>&1 &
        save_pid $!
        for i in $(seq 1 20); do
            tunnel_url=$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | grep -oE '"public_url":"[^"]+"' | sed 's/"public_url":"//;s/"//' | head -1)
            [[ -n "$tunnel_url" ]] && break
            sleep 2
        done
    fi

    # Mostrar info
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ MÁQUINA VIRTUAL LISTA${NC}"
    if [[ -n "$tunnel_url" ]]; then
        echo -e "${GREEN}  🌍 URL:${NC} ${tunnel_url}"
    else
        echo -e "${GREEN}  🌍 URL local: http://127.0.0.1:${NOVNC_PORT}${NC}"
    fi
    echo -e "${YELLOW}  💡 Contraseña VNC: colab123${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================
# HELP
# ============================================================
mostrar_ayuda() {
    cat <<EOF
USO: $0 "URL" [RAM_MB]
EJEMPLOS:
  $0 "https://archive.org/details/ubuntu-24.04-desktop"
  $0 "https://www.mediafire.com/file/abc123/ubuntu.iso" 8192
SOPORTA: Mediafire, Archive.org, Google Drive, enlaces directos
EOF
}

# ============================================================
# MAIN
# ============================================================

[[ -z "$URL" || "$URL" == "-h" || "$URL" == "--help" ]] && { mostrar_ayuda; exit 0; }

echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}     📥 QEMU UNIVERSAL BOOT v4.0${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"

instalar_deps

DIRECT_URL=$(resolver_url "$URL")
log "$GREEN" "URL: $(echo "$DIRECT_URL" | sed 's/?.*//')"

FILENAME=$(get_filename "$DIRECT_URL")
log "$CYAN" "Archivo: $FILENAME"

rm -rf "$WORKDIR" 2>/dev/null; mkdir -p "$WORKDIR" 2>/dev/null

descargar "$DIRECT_URL" "$FILENAME" || { err "Descarga fallida"; exit 1; }

if echo "$FILENAME" | grep -qiE '\.(7z|zip|tar\.gz|tgz|tar\.xz|tar\.bz2|xz|bz2)$'; then
    extraer_si_necesario "$FILENAME" "$WORKDIR"
else
    cp "$FILENAME" "$WORKDIR/" 2>/dev/null
fi

IMAGEN=$(buscar_imagen "$WORKDIR")
if [[ -z "$IMAGEN" ]]; then
    err "No se encontró imagen booteable"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    exit 1
fi

iniciar_qemu "$IMAGEN" || exit 1
iniciar_remoto

log "$GREEN" "✅ Todo listo. Ctrl+C para detener."
while true; do sleep 60; done
