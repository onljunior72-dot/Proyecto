#!/bin/bash
# ============================================================
# DESCARGADOR UNIVERSAL + QEMU BOOT v3.1 (Cloudflare only, tolerante)
# ============================================================
set +euo pipefail   # ← Ahora errores no detienen el script

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'

URL="${1:-}"
RAM_MB="${2:-4096}"
VNC_PORT=7
NOVNC_PORT=6081
WORKDIR="/content/qemu_work"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="/tmp/qemu_launcher.pids"

# Cleanup handler
cleanup() {
    echo -e "\n${YELLOW}Limpiando procesos...${NC}"
    [[ -f "$PIDFILE" ]] && while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$PIDFILE"
    pkill -f "qemu-system-x86_64" 2>/dev/null || true
    pkill -f "websockify" 2>/dev/null || true
    pkill -f "cloudflared" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo -e "${GREEN}OK${NC}"
}
trap cleanup EXIT INT TERM

save_pid() {
    echo $1 >> "$PIDFILE"
}

log() {
    local color="$1"; shift
    echo -e "${color}[$(date +%H:%M:%S)]${NC} $*"
}

err() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ============================================================
# 1. Instalar dependencias (Robusta, sin ngrok, con cloudflared binario)
# ============================================================
instalar_deps() {
    log "$YELLOW" "🔧 Instalando dependencias..."

    # Python3 por si acaso
    command -v python3 &>/dev/null || apt-get install -y -qq python3 >/dev/null 2>&1 || true

    local pkgs=(
        qemu-system-x86 qemu-utils novnc websockify
        p7zip-full unzip xz-utils bzip2 gzip curl
        wget bc
    )

    rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true

    # Reintentos de instalación
    for ((i=1; i<=3; i++)); do
        if apt-get update -qq 2>/dev/null && apt-get install -y -qq --fix-missing "${pkgs[@]}" >/dev/null 2>&1; then
            break
        fi
        log "$YELLOW" "  Reintento $i..."
        sleep 3
    done

    # Instalación plan B sin fix-missing
    apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 || true

    # Verificar QEMU
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        err "QEMU no se instaló. Intentando forzar..."
        apt-get install -y qemu-system-x86 qemu-utils >/dev/null 2>&1 || true
    fi

    # ============================================================
    # Instalar CLOUDFLARE (binario, siempre funciona en Colab)
    # ============================================================
    if ! command -v cloudflared &>/dev/null; then
        log "$YELLOW" "☁️ Instalando Cloudflare Tunnel (binario estático)..."
        curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
            -o /usr/local/bin/cloudflared 2>/dev/null || \
        wget -q --no-check-certificate \
            https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
            -O /usr/local/bin/cloudflared 2>/dev/null || true
        chmod +x /usr/local/bin/cloudflared 2>/dev/null
        ln -sf /usr/local/bin/cloudflared /usr/bin/cloudflared 2>/dev/null
        log "$GREEN" "  cloudflared instalado"
    else
        log "$GREEN" "  cloudflared ya presente"
    fi

    log "$GREEN" "Dependencias listas."
}

# ============================================================
# 2. Resolver URL (multi-método) – todas las funciones llevan || true
# ============================================================
resolver_url() {
    local url="$1"
    local resolved=""

    log "$YELLOW" "Analizando URL..."

    if [[ "$url" == *"mediafire.com"* ]]; then
        log "$CYAN" "Mediafire detectado"
        resolved=$(resolver_mediafire "$url") || true
        if [[ -n "$resolved" ]]; then echo "$resolved"; return; fi
    fi

    if [[ "$url" == *"archive.org"* ]]; then
        log "$CYAN" "Archive.org detectado"
        resolved=$(resolver_archive "$url") || true
        if [[ -n "$resolved" ]]; then echo "$resolved"; return; fi
    fi

    if [[ "$url" == *"drive.google.com"* ]]; then
        log "$CYAN" "Google Drive detectado"
        resolved=$(resolver_gdrive "$url") || true
        if [[ -n "$resolved" ]]; then echo "$resolved"; return; fi
    fi

    if [[ "$url" =~ \.(iso|7z|vhd|vhdx|qcow2|img|vmdk|zip|tgz|tar\.gz|tar\.xz|tar\.bz2)(\?|$) ]] || \
       [[ "$url" == */download/* ]] || [[ "$url" == *github.com/releases* ]]; then
        echo "$url"
        return
    fi

    # Fallback Content-Disposition
    log "$YELLOW" "Probando resolución por Content-Disposition..."
    test_url=$(curl -sI -L -A "Mozilla/5.0" "$url" 2>/dev/null | \
        grep -i "^content-disposition:" | sed 's/.*filename=//; s/"//g' | tr -d '\r' || true)
    if [[ -n "$test_url" ]]; then
        echo "$url"
        return
    fi

    echo "$url"
}

# --- Mediafire ---
resolver_mediafire() {
    local url="$1"
    local file_id

    file_id=$(echo "$url" | grep -oP '/file/\K[^/?]+' | head -1 || true)
    [[ -z "$file_id" ]] && file_id=$(echo "$url" | grep -oP '/\w{15,}\b' | head -1 | tr -d '/' || true)
    [[ -z "$file_id" ]] && { err "No se pudo extraer ID de Mediafire"; echo ""; return; }

    log "$CYAN" "  ID: $file_id"
    local page_url="https://www.mediafire.com/file/${file_id}/"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    local html
    html=$(wget -qO- --timeout=15 --user-agent="$ua" "$page_url" 2>/dev/null || true)
    [[ -z "$html" ]] && html=$(curl -sL --max-time 15 -A "$ua" "$page_url" 2>/dev/null || true)
    [[ -z "$html" ]] && { err "No se pudo obtener página de Mediafire"; echo ""; return; }

    local direct=""
    direct=$(echo "$html" | grep -oP 'https?://download\d+\.mediafire\.com[^"'"'"' <>]+' | head -1 || true)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oP 'href="[^"]*download[^"]*mediafire[^"]*"' | sed 's/href="//;s/"//' | head -1 || true)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oP 'aria-label="[Dd]ownload"[^>]*href="\K[^"]+' | head -1 || true)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oP 'id="downloadButton"[^>]*href="\K[^"]+' | head -1 || true)
    [[ -z "$direct" ]] && direct=$(echo "$html" | grep -oP '"url":"[^"]*mediafire[^"]*"' | sed 's/"url":"//;s/"//' | sed 's/\\//g' | head -1 || true)

    if [[ -n "$direct" ]]; then
        log "$GREEN" "  Enlace directo extraído"
        echo "$direct"
    else
        err "No se pudo extraer enlace de Mediafire"
        echo ""
    fi
}

# --- Archive.org ---
resolver_archive() {
    local url="$1"
    local item_id
    item_id=$(echo "$url" | grep -oP '(?:details|download)/\K[^/?#]+' | head -1 || true)
    [[ -z "$item_id" ]] && { err "No se pudo extraer ID de Archive.org"; echo ""; return; }

    log "$CYAN" "  Item: $item_id"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    local api_url="https://archive.org/metadata/${item_id}"
    local metadata
    metadata=$(curl -sL --max-time 15 "$api_url" 2>/dev/null || wget -qO- --timeout=15 "$api_url" 2>/dev/null || true)

    if [[ -z "$metadata" ]]; then
        local page
        page=$(curl -sL --max-time 15 -A "$ua" "https://archive.org/details/${item_id}" 2>/dev/null || true)
        local files
        files=$(echo "$page" | grep -oP 'https://archive\.org/download/[^"'"'"' <>]+\.(iso|img|vhd|vhdx|qcow2|vmdk|7z|zip|raw|tar\.gz|tgz|xz|bz2)' | sort -u | head -5 || true)
        if [[ -n "$files" ]]; then
            log "$GREEN" "  Archivos encontrados:"
            echo "$files" | while IFS= read -r f; do log "$CYAN" "    $f"; done
            echo "$files" | head -1
            return
        fi
        err "No se pudo obtener metadata"
        echo ""
        return
    fi

    if command -v python3 &>/dev/null; then
        local file_list
        file_list=$(python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    files = data.get('files', [])
    exts = ['iso', 'img', 'vhd', 'vhdx', 'qcow2', 'vmdk', '7z', 'zip', 'raw', 'tar.gz', 'tgz', 'xz', 'bz2']
    best = None
    for f in files:
        name = f.get('name', '')
        for ext in exts:
            if name.endswith('.' + ext):
                if best is None or f.get('size', 0) > best.get('size', 0):
                    best = f
                break
    if best: print(best['name'])
    else:
        for f in sorted(files, key=lambda x: int(x.get('size', 0) or 0), reverse=True):
            print(f['name'])
            break
except: pass
" <<< "$metadata" 2>/dev/null || true)
        if [[ -n "$file_list" ]]; then
            echo "https://archive.org/download/${item_id}/${file_list}"
            return
        fi
    fi

    local page2
    page2=$(curl -sL --max-time 15 -A "$ua" "https://archive.org/details/${item_id}" 2>/dev/null || true)
    local direct_links
    direct_links=$(echo "$page2" | grep -oP "https://archive\.org/download/[^\"' <>]+\.(iso|img|vhd|vhdx|qcow2|vmdk|7z|zip)" | sort -u | head -1 || true)
    if [[ -n "$direct_links" ]]; then
        echo "$direct_links"
    else
        err "No se encontraron archivos descargables en Archive.org"
        echo ""
    fi
}

# --- Google Drive ---
resolver_gdrive() {
    local url="$1"
    local file_id
    file_id=$(echo "$url" | grep -oP '/d/\K[^/?#]+' | head -1 || true)
    [[ -z "$file_id" ]] && file_id=$(echo "$url" | grep -oP 'id=\K[^&?#]+' | head -1 || true)
    [[ -z "$file_id" ]] && { err "No se pudo extraer ID de Google Drive"; echo ""; return; }

    if command -v gdown &>/dev/null; then
        echo "gdrive+gdown://$file_id"
        return
    fi
    echo "https://drive.google.com/uc?export=download&id=${file_id}&confirm=t"
}

# ============================================================
# 3. Obtener nombre de archivo
# ============================================================
get_filename() {
    local url="$1"
    local filename=""

    if command -v curl &>/dev/null; then
        filename=$(curl -sI -L -A "Mozilla/5.0" "$url" 2>/dev/null | \
            grep -i "^content-disposition:" | sed 's/.*filename="\?//; s/"\?\s*$//; s/\r//' | tail -1 || true)
    fi

    if [[ -z "$filename" || "$filename" == *"??"* ]]; then
        filename=$(basename "$url" | sed 's/\?.*//')
        filename=$(python3 -c "
import urllib.parse, sys
try:
    print(urllib.parse.unquote('${filename}'))
except:
    print('${filename}')
" 2>/dev/null || echo "$filename")
    fi

    filename=$(echo "$filename" | sed 's/[\/:*?"<>|]/-/g')
    [[ -z "$filename" || "${#filename}" -lt 4 ]] && filename="downloaded_file.iso"
    echo "$filename"
}

# ============================================================
# 4. Descargar archivo (robusto)
# ============================================================
descargar() {
    local url="$1"
    local filename="$2"
    local expected_size="${3:-0}"

    # Si ya existe y es grande, seguir
    if [[ -f "$filename" ]]; then
        local size
        size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        if [[ "$size" -gt 1000000 ]]; then
            local size_mb
            size_mb=$(echo "scale=2; $size/1048576" | bc 2>/dev/null || echo "$((size/1048576))")
            log "$GREEN" "Archivo existe: $(basename "$filename") (${size_mb} MB)"
            [[ "$expected_size" -gt 0 && "$size" -lt "$expected_size" ]] || return 0
        else
            rm -f "$filename"
        fi
    fi

    log "$YELLOW" "Descargando: $(basename "$filename")"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    # Caso gdown
    if [[ "$url" == gdrive+gdown://* ]]; then
        local fid="${url#gdrive+gdown://}"
        if command -v gdown &>/dev/null; then
            gdown --fuzzy "$fid" -O "$filename" --remaining-ok 2>&1 | tail -5 || true
            [[ -f "$filename" ]] && return 0 || return 1
        fi
    fi

    # Caso Google Drive
    if [[ "$url" == *"drive.google.com/uc?export=download"* ]]; then
        log "$CYAN" "  Google Drive: manejando confirmación..."
        local cookie="/tmp/gdrive_cookie.txt"
        rm -f "$cookie"
        curl -sc "$cookie" -L -A "$ua" "$url" > /dev/null 2>&1 || true
        local confirm
        confirm=$(curl -sb "$cookie" -L -A "$ua" "$url" 2>/dev/null | grep -oP 'confirm=\K[a-zA-Z0-9_-]+' | head -1 || true)
        [[ -n "$confirm" ]] && url="${url}&confirm=${confirm}"
    fi

    local success=0
    local temp_file="${filename}.part"
    rm -f "$temp_file"

    log "$CYAN" "  wget..."
    if wget --timeout=30 --tries=5 --waitretry=10 --retry-connrefused --continue \
        --no-check-certificate --content-disposition --user-agent="$ua" \
        -O "$temp_file" "$url" 2>&1 | grep -E "(100%|saved|downloaded)" | tail -1; then
        [[ -f "$temp_file" ]] && mv "$temp_file" "$filename" && success=1
    fi

    if [[ "$success" -eq 0 ]]; then
        log "$YELLOW" "  wget falló, probando curl..."
        rm -f "$temp_file"
        if curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 --max-time 7200 -C - \
            -A "$ua" -o "$temp_file" "$url" 2>&1 | tail -3; then
            [[ -f "$temp_file" ]] && mv "$temp_file" "$filename" && success=1
        fi
    fi

    if [[ -f "$filename" ]]; then
        local size size_mb
        size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        size_mb=$(echo "scale=2; $size/1048576" | bc 2>/dev/null || echo "$((size/1048576))")
        [[ "$size" -lt 500000 ]] && { err "Archivo muy pequeño (${size_mb} MB)"; return 1; }
        log "$GREEN" "Descargado: $(basename "$filename") (${size_mb} MB)"
        return 0
    fi

    err "Falló la descarga"
    return 1
}

# ============================================================
# 5-6. Extracción y búsqueda (sin cambios, solo añadidos || true en greps)
# ============================================================
extraer_si_necesario() {
    local archivo="$1"
    local dir="$2"
    local encontro_imagen=0
    mkdir -p "$dir"

    local nombre_ext=$(basename "$archivo" | tr '[:upper:]' '[:lower:]')
    case "$nombre_ext" in
        *.7z)  7z x -y -o"$dir" "$archivo" > /dev/null 2>&1 || true
                while IFS= read -r f; do 7z x -y -o"$dir" "$f" > /dev/null 2>&1 || true; done < <(find "$dir" -maxdepth 2 -name "*.7z" -type f 2>/dev/null || true) ;;
        *.zip) unzip -o -q "$archivo" -d "$dir" 2>/dev/null || true ;;
        *.tar.gz|*.tgz) tar -xzf "$archivo" -C "$dir" 2>/dev/null || true ;;
        *.tar.xz|*.txz) tar -xJf "$archivo" -C "$dir" 2>/dev/null || true ;;
        *.tar.bz2|*.tbz2) tar -xjf "$archivo" -C "$dir" 2>/dev/null || true ;;
        *.xz) xz -dk "$archivo" --stdout > "${dir}/$(basename "$archivo" .xz)" 2>/dev/null || true ;;
        *.bz2) bzip2 -dk "$archivo" --stdout > "${dir}/$(basename "$archivo" .bz2)" 2>/dev/null || true ;;
        *.iso|*.vhd|*.vhdx|*.qcow2|*.img|*.vmdk|*.raw)
            cp "$archivo" "$dir/" ; encontro_imagen=1 ;;
        *) cp "$archivo" "$dir/" ;;
    esac

    [[ "$encontro_imagen" -eq 0 ]] && { local found; found=$(buscar_imagen "$dir" 2>/dev/null || true); [[ -n "$found" ]] && encontro_imagen=1; }
    return $encontro_imagen
}

buscar_imagen() {
    local dir="$1"
    local best=""
    local best_size=0
    log "$YELLOW" "Buscando imagen booteable..."

    local exts=("vhd" "vhdx" "img" "qcow2" "vmdk" "raw" "iso")
    for ext in "${exts[@]}"; do
        while IFS= read -r -d '' f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            local priority=0
            [[ "$ext" == "iso" ]] && priority=10000
            local total=$((size + priority))
            if [[ "$total" -gt "$best_size" && "$size_mb" -gt 50 ]]; then
                best="$f"
                best_size="$total"
            fi
        done < <(find "$dir" -type f -iname "*.${ext}" -print0 2>/dev/null || true)
    done

    [[ -z "$best" ]] && {
        while IFS= read -r -d '' f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            [[ "$size" -gt "$best_size" && $((size/1048576)) -gt 500 ]] && { best="$f"; best_size="$size"; }
        done < <(find "$dir" -type f -size +500M -print0 2>/dev/null || true)
    }

    if [[ -n "$best" ]]; then
        local size_gb=$(echo "scale=2; $best_size/1073741824" | bc 2>/dev/null || echo "?")
        log "$GREEN" "Seleccionado: $(basename "$best") (${size_gb} GB)"
        echo "$best"
    else
        echo ""
    fi
}

# ============================================================
# 7. Iniciar QEMU (con fallbacks)
# ============================================================
iniciar_qemu() {
    local imagen="$1"
    local ext=$(echo "${imagen##*.}" | tr '[:upper:]' '[:lower:]')
    local format="raw"; local media="disk"; local boot="c"

    case "$ext" in
        vhd|vpc) format="vpc" ;;
        vhdx) format="vhdx" ;;
        qcow2) format="qcow2" ;;
        img|raw) format="raw" ;;
        iso) format="raw"; media="cdrom"; boot="d" ;;
        vmdk) format="vmdk" ;;
    esac

    log "$YELLOW" "Iniciando QEMU (${RAM_MB} MB RAM, formato: ${format})..."
    pkill -f "qemu-system-x86_64" 2>/dev/null || true
    sleep 2

    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        log "$YELLOW" "Puerto VNC ocupado, usando $((5900 + VNC_PORT + 1))..."
        VNC_PORT=$((VNC_PORT + 1))
    fi

    local accel="tcg,thread=multi"
    [[ -e /dev/kvm ]] && accel="kvm"
    local cpus=$(nproc 2>/dev/null || echo "2")
    [[ "$cpus" -gt 4 ]] && cpus=4

    local base_args=(-m "$RAM_MB" -smp "$cpus" -cpu max -accel "$accel" -machine type=pc
                     -vga std -display vnc=:$VNC_PORT -usb -device usb-tablet -rtc base=localtime)
    local net_args=(-netdev user,id=net0 -device e1000,netdev=net0)

    if [[ "$media" == "cdrom" ]]; then
        local disk_img="/content/qemu_disk.qcow2"
        [[ ! -f "$disk_img" ]] && qemu-img create -f qcow2 "$disk_img" 60G > /dev/null 2>&1
        qemu-system-x86_64 "${base_args[@]}" -drive file="$disk_img",format=qcow2,index=0,media=disk \
            -drive file="$imagen",format=raw,index=1,media=cdrom -boot d "${net_args[@]}" > /dev/null 2>&1 &
        save_pid $!
    else
        qemu-system-x86_64 "${base_args[@]}" -drive file="$imagen",format="$format",if=ide,index=0 \
            -boot c "${net_args[@]}" > /dev/null 2>&1 &
        save_pid $!
    fi

    local qemu_pid=$!
    for i in {1..12}; do
        sleep 2
        if kill -0 "$qemu_pid" 2>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
                log "$GREEN" "QEMU corriendo en puerto VNC $VNC_PORT"
                return 0
            fi
        else
            break
        fi
    done

    err "QEMU no respondió"
    return 1
}

# ============================================================
# 8. Túnel (SOLO Cloudflare, sin ngrok)
# ============================================================
iniciar_remoto() {
    log "$YELLOW" "Iniciando noVNC..."
    local novnc_dir=""
    for d in "/usr/share/novnc" "/usr/share/noVNC" "/usr/local/share/novnc"; do
        [[ -d "$d" ]] && { novnc_dir="$d"; break; }
    done

    if [[ -z "$novnc_dir" ]]; then
        novnc_dir="/tmp/noVNC"
        if [[ ! -d "$novnc_dir" ]]; then
            git clone --depth 1 https://github.com/novnc/noVNC.git "$novnc_dir" 2>/dev/null || \
            wget -qO- https://github.com/novnc/noVNC/archive/refs/heads/master.tar.gz | \
                tar -xz -C /tmp/ 2>/dev/null && novnc_dir="/tmp/noVNC-master" || true
        fi
    fi

    if [[ -d "$novnc_dir" ]]; then
        websockify --web "$novnc_dir" "$NOVNC_PORT" "localhost:590${VNC_PORT}" > /dev/null 2>&1 &
        save_pid $!
        sleep 2
        log "$GREEN" "  noVNC en puerto $NOVNC_PORT"
    else
        log "$YELLOW" "  noVNC no disponible, VNC directo en :$VNC_PORT"
    fi

    # Tunnel (Cloudflare)
    log "$YELLOW" "Iniciando túnel Cloudflare..."
    local tunnel_url=""
    if command -v cloudflared &>/dev/null; then
        cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${NOVNC_PORT}" \
            > /tmp/cloudflared.log 2>&1 &
        save_pid $!
        for i in {1..30}; do
            tunnel_url=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1 || true)
            [[ -n "$tunnel_url" ]] && break
            sleep 2
        done
    else
        log "$YELLOW" "  cloudflared no encontrado (no se pudo instalar)"
    fi

    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}  ✅ MÁQUINA VIRTUAL LISTA${NC}"
    echo -e "${BLUE}============================================================${NC}"
    if [[ -n "$tunnel_url" ]]; then
        echo -e "${GREEN}  🌍 URL:${NC} ${tunnel_url}"
    else
        log "$YELLOW" "  No se pudo obtener URL pública. Si estás en Colab, usa un túnel manual o verifica cloudflared."
    fi
    echo -e "${YELLOW}  💡 Contraseña VNC: colab123${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

# ============================================================
# MAIN
# ============================================================
if [[ -z "$URL" || "$URL" == "-h" || "$URL" == "--help" ]]; then
    cat <<EOF
USO: $0 "URL" [RAM_MB]
Soporta: Mediafire, Archive.org, Google Drive, enlaces directos.
Formatos: ISO, 7z, VHD, VHDX, QCOW2, IMG, VMDK, ZIP, TAR.GZ, TGZ, XZ, BZ2.
EOF
    exit 0
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     📥 DESCARGADOR UNIVERSAL + QEMU v3.1 (Cloudflare)${NC}"
echo -e "${BLUE}============================================================${NC}"

instalar_deps

DIRECT_URL=$(resolver_url "$URL") || true
if [[ -z "$DIRECT_URL" ]]; then
    err "No se pudo resolver la URL, intentando con la original."
    DIRECT_URL="$URL"
fi
log "$GREEN" "URL final: $(echo "$DIRECT_URL" | sed 's/?.*//')"

FILENAME=$(get_filename "$DIRECT_URL")
log "$CYAN" "Archivo: $FILENAME"

rm -rf "$WORKDIR" 2>/dev/null || true
mkdir -p "$WORKDIR"

if ! descargar "$DIRECT_URL" "$FILENAME"; then
    err "Descarga fallida. Verifica la URL."
    exit 1
fi

if [[ "$FILENAME" =~ \.(7z|zip|tar\.gz|tgz|tar\.xz|tar\.bz2|xz|bz2)$ ]]; then
    extraer_si_necesario "$FILENAME" "$WORKDIR" || true
else
    cp "$FILENAME" "$WORKDIR/" 2>/dev/null || true
fi

IMAGEN=$(buscar_imagen "$WORKDIR") || true
if [[ -z "$IMAGEN" ]]; then
    err "No se encontró ninguna imagen booteable."
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    exit 1
fi

if ! iniciar_qemu "$IMAGEN"; then
    err "QEMU no pudo iniciar."
    exit 1
fi

iniciar_remoto

log "$GREEN" "Script completado. Manteniendo procesos activos..."
log "$YELLOW" "Presiona Ctrl+C para detener todo."

# Bucle infinito que mantiene el script (y la celda) vivo
while true; do
    sleep 60
done
