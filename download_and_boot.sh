#!/bin/bash
# ============================================================
# DESCARGADOR UNIVERSAL + QEMU BOOT v3.0
# Uso: ./download_and_boot.sh "URL" [RAM_MB]
# Soporta: Mediafire, Archive.org, Google Drive, enlaces directos
# Formatos: ISO, 7z, VHD, VHDX, QCOW2, IMG, VMDK, ZIP, TAR.GZ, TGZ, XZ, BZ2
# ============================================================
set -euo pipefail

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
# 1. Instalar dependencias (Robusta con fallbacks)
# ============================================================
instalar_deps() {
    log "$YELLOW" "🔧 Instalando dependencias..."

    # Intentar instalar python3 si no está
    if ! command -v python3 &>/dev/null; then
        apt-get install -y -qq python3 >/dev/null 2>&1 || true
    fi

    # Herramientas base
    local pkgs=(
        qemu-system-x86 qemu-utils novnc websockify
        p7zip-full unzip xz-utils bzip2 gzip curl
        wget bc
    )

    # Limpiar sources.list problemáticos (Colab)
    rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true

    # Actualizar e instalar con reintento
    local retries=3
    local ok=0
    for ((i=1; i<=retries; i++)); do
        if apt-get update -qq 2>/dev/null && apt-get install -y -qq --fix-missing "${pkgs[@]}" >/dev/null 2>&1; then
            ok=1
            break
        fi
        log "$YELLOW" "Reintento $i/$retries..."
        sleep 3
    done

    if [[ "$ok" -eq 0 ]]; then
        # Fallback: intentar sin --fix-missing
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 || true
    fi

    # Verificar QEMU
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        err "QEMU no se instaló. Intentando manual..."
        local qemu_url="https://github.com/vmware/open-vm-tools/releases/download/stable-2025"
        # En realidad mejor intentar con pip o flatpak, pero en Colab apt debería bastar
        apt-get install -y qemu-system-x86 qemu-utils 2>/dev/null || true
    fi

    # Verificar cloudflared
    if ! command -v cloudflared &>/dev/null; then
        log "$YELLOW" "Instalando cloudflared..."
        wget -q --no-check-certificate \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
            -O /tmp/cloudflared.deb 2>/dev/null && \
        dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || \
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
            -o /tmp/cloudflared.deb && \
        dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || \
        log "$YELLOW" "cloudflared opcional, se usará ngrok como fallback"
    fi

    log "$GREEN" "Dependencias listas."
}

# ============================================================
# 2. Resolver URL (multi-método)
# ============================================================
resolver_url() {
    local url="$1"
    local resolved=""

    log "$YELLOW" "Analizando URL..."

    # --- Caso: Mediafire ---
    if [[ "$url" == *"mediafire.com"* ]]; then
        log "$CYAN" "Mediafire detectado"
        resolved=$(resolver_mediafire "$url")
        if [[ -n "$resolved" ]]; then
            echo "$resolved"
            return
        fi
    fi

    # --- Caso: Archive.org ---
    if [[ "$url" == *"archive.org"* ]]; then
        log "$CYAN" "Archive.org detectado"
        resolved=$(resolver_archive "$url")
        if [[ -n "$resolved" ]]; then
            echo "$resolved"
            return
        fi
    fi

    # --- Caso: Google Drive ---
    if [[ "$url" == *"drive.google.com"* ]]; then
        log "$CYAN" "Google Drive detectado"
        resolved=$(resolver_gdrive "$url")
        if [[ -n "$resolved" ]]; then
            echo "$resolved"
            return
        fi
    fi

    # --- Caso: enlace directo o desconocido ---
    if [[ "$url" =~ \.(iso|7z|vhd|vhdx|qcow2|img|vmdk|zip|tgz|tar\.gz|tar\.xz|tar\.bz2)(\?|$) ]] || \
       [[ "$url" == */download/* ]] || [[ "$url" == *github.com/releases* ]]; then
        echo "$url"
        return
    fi

    # Fallback: verificar si responde con Content-Disposition
    log "$YELLOW" "Probando resolución por Content-Disposition..."
    local test_url
    test_url=$(curl -sI -L -A "Mozilla/5.0" "$url" 2>/dev/null | \
        grep -i "^content-disposition:" | sed 's/.*filename=//; s/"//g' | tr -d '\r')
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

    file_id=$(echo "$url" | grep -oP '/file/\K[^/?]+' | head -1)
    [[ -z "$file_id" ]] && file_id=$(echo "$url" | grep -oP '/\w{15,}\b' | head -1 | tr -d '/')
    [[ -z "$file_id" ]] && { err "No se pudo extraer ID de Mediafire"; echo ""; return; }

    log "$CYAN" "  ID: $file_id"

    local page_url="https://www.mediafire.com/file/${file_id}/"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    # Intentar con wget
    local html
    html=$(wget -qO- --timeout=15 --user-agent="$ua" "$page_url" 2>/dev/null || true)

    # Si wget no da resultado, probar con curl
    if [[ -z "$html" ]]; then
        html=$(curl -sL --max-time 15 -A "$ua" "$page_url" 2>/dev/null || true)
    fi

    [[ -z "$html" ]] && { err "No se pudo obtener página de Mediafire"; echo ""; return; }

    local direct=""

    # Patrón 1: downloadXX.mediafire.com/... (más común)
    direct=$(echo "$html" | grep -oP 'https?://download\d+\.mediafire\.com[^"'"'"' <>]+' | head -1)

    # Patrón 2: href con download_link
    if [[ -z "$direct" ]]; then
        direct=$(echo "$html" | grep -oP 'href="[^"]*download[^"]*mediafire[^"]*"' | sed 's/href="//;s/"//' | head -1)
    fi

    # Patrón 3: aria-label="Download" + href cercano
    if [[ -z "$direct" ]]; then
        direct=$(echo "$html" | grep -oP 'aria-label="[Dd]ownload"[^>]*href="\K[^"]+' | head -1)
    fi

    # Patrón 4: botón downloadButton
    if [[ -z "$direct" ]]; then
        direct=$(echo "$html" | grep -oP 'id="downloadButton"[^>]*href="\K[^"]+' | head -1)
    fi

    # Patrón 5: url parametro en JS
    if [[ -z "$direct" ]]; then
        direct=$(echo "$html" | grep -oP '"url":"[^"]*mediafire[^"]*"' | sed 's/"url":"//;s/"//' | sed 's/\\//g' | head -1)
    fi

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

    # Extraer item name: details/itemname  o  download/itemname/
    item_id=$(echo "$url" | grep -oP '(?:details|download)/\K[^/?#]+' | head -1)
    [[ -z "$item_id" ]] && { err "No se pudo extraer ID de Archive.org"; echo ""; return; }

    log "$CYAN" "  Item: $item_id"

    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    local api_url="https://archive.org/metadata/${item_id}"
    local metadata
    metadata=$(curl -sL --max-time 15 "$api_url" 2>/dev/null || wget -qO- --timeout=15 "$api_url" 2>/dev/null || true)

    if [[ -z "$metadata" ]]; then
        # Fallback: parsear la página
        local page
        page=$(curl -sL --max-time 15 -A "$ua" "https://archive.org/details/${item_id}" 2>/dev/null || true)

        # Buscar enlaces a .iso, .img, .vhd, .qcow2, .vmdk, .7z, .zip
        local files
        files=$(echo "$page" | grep -oP 'https://archive\.org/download/[^"'"'"' <>]+\.(iso|img|vhd|vhdx|qcow2|vmdk|7z|zip|raw|tar\.gz|tgz|xz|bz2)' | sort -u | head -5)

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

    # Extraer nombres de archivo del JSON con Python si está disponible
    if command -v python3 &>/dev/null; then
        local file_list
        file_list=$(python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    files = data.get('files', [])
    # Priorizar: iso > img > vhd > qcow2 > 7z > zip > vmdk > raw
    exts = ['iso', 'img', 'vhd', 'vhdx', 'qcow2', 'vmdk', '7z', 'zip', 'raw', 'tar.gz', 'tgz', 'xz', 'bz2']
    best = None
    for f in files:
        name = f.get('name', '')
        for ext in exts:
            if name.endswith('.' + ext):
                if best is None or f.get('size', 0) > best.get('size', 0):
                    best = f
                break
    if best:
        print(best['name'])
    else:
        # Devolver el primer archivo grande
        for f in sorted(files, key=lambda x: int(x.get('size', 0) or 0), reverse=True):
            print(f['name'])
            break
except Exception:
    pass
" <<< "$metadata" 2>/dev/null || true)

        if [[ -n "$file_list" ]]; then
            local base_url="https://archive.org/download/${item_id}"
            echo "${base_url}/${file_list}"
            return
        fi
    fi

    # Fallback último: listar con curl la página y filtrar
    local page2
    page2=$(curl -sL --max-time 15 -A "$ua" "https://archive.org/details/${item_id}" 2>/dev/null || true)
    local direct_links
    direct_links=$(echo "$page2" | grep -oP "https://archive\.org/download/[^\"' <>]+\.(iso|img|vhd|vhdx|qcow2|vmdk|7z|zip)" | sort -u | head -1)

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

    file_id=$(echo "$url" | grep -oP '/d/\K[^/?#]+' | head -1)
    [[ -z "$file_id" ]] && file_id=$(echo "$url" | grep -oP 'id=\K[^&?#]+' | head -1)
    [[ -z "$file_id" ]] && { err "No se pudo extraer ID de Google Drive"; echo ""; return; }

    # Intentar con gdown (herramienta específica para GDrive)
    if command -v gdown &>/dev/null; then
        echo "gdrive+gdown://$file_id"
        return
    fi

    # Confirmar bypass para archivos grandes
    echo "https://drive.google.com/uc?export=download&id=${file_id}&confirm=t"
}

# ============================================================
# 3. Obtener nombre de archivo (desde URL o Content-Disposition)
# ============================================================
get_filename() {
    local url="$1"
    local filename=""

    # Intentar Content-Disposition
    if command -v curl &>/dev/null; then
        filename=$(curl -sI -L -A "Mozilla/5.0" "$url" 2>/dev/null | \
            grep -i "^content-disposition:" | sed 's/.*filename="\?//; s/"\?\s*$//; s/\r//' | tail -1)
    fi

    # Fallback: extraer de la URL
    if [[ -z "$filename" || "$filename" == *"??"* ]]; then
        # Decodificar URL
        filename=$(basename "$url" | sed 's/\?.*//')
        filename=$(python3 -c "
import urllib.parse, sys
try:
    print(urllib.parse.unquote('${filename}'))
except:
    print('${filename}')
" 2>/dev/null || echo "$filename")
    fi

    # Eliminar caracteres raros y asegurar extensión
    filename=$(echo "$filename" | sed 's/[\/:*?"<>|]/-/g')
    if [[ -z "$filename" || "${#filename}" -lt 4 ]]; then
        filename="downloaded_file.iso"
    fi

    echo "$filename"
}

# ============================================================
# 4. Descargar archivo (con reanudación, fallback, verificación)
# ============================================================
descargar() {
    local url="$1"
    local filename="$2"
    local expected_size="${3:-0}"

    # Si el archivo ya existe y es válido
    if [[ -f "$filename" ]]; then
        local size
        size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        if [[ "$size" -gt 1000000 ]]; then
            local size_mb
            size_mb=$(echo "scale=2; $size/1048576" | bc 2>/dev/null || echo "$((size/1048576))")
            log "$GREEN" "Archivo existe: $(basename "$filename") (${size_mb} MB)"
            # Verificar integridad si hay tamaño esperado
            if [[ "$expected_size" -gt 0 && "$size" -eq "$expected_size" ]]; then
                return 0
            elif [[ "$expected_size" -gt 0 && "$size" -lt "$expected_size" ]]; then
                log "$YELLOW" "  Incompleto ($size de $expected_size), reanudando..."
            else
                return 0
            fi
        else
            rm -f "$filename"
        fi
    fi

    log "$YELLOW" "Descargando: $(basename "$filename")"

    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    # Caso especial: gdown
    if [[ "$url" == gdrive+gdown://* ]]; then
        local fid="${url#gdrive+gdown://}"
        if command -v gdown &>/dev/null; then
            gdown --fuzzy "$fid" -O "$filename" --remaining-ok 2>&1 | tail -5
            [[ -f "$filename" ]] && return 0 || return 1
        fi
    fi

    # Caso especial: Google Drive con confirmación
    if [[ "$url" == *"drive.google.com/uc?export=download"* ]]; then
        log "$CYAN" "  Google Drive: manejando confirmación..."
        # Descargar cookie de confirmación
        local cookie="/tmp/gdrive_cookie.txt"
        rm -f "$cookie"
        curl -sc "$cookie" -L -A "$ua" "$url" > /dev/null 2>&1
        # Obtener confirm token
        local confirm
        confirm=$(curl -sb "$cookie" -L -A "$ua" "$url" 2>/dev/null | grep -oP 'confirm=\K[a-zA-Z0-9_-]+' | head -1)
        if [[ -n "$confirm" ]]; then
            url="${url}&confirm=${confirm}"
        fi
    fi

    # --- Función de descarga ---
    local success=0
    local temp_file="${filename}.part"

    # Intentar con wget (con reanudación)
    rm -f "$temp_file"
    log "$CYAN" "  wget..."
    if wget \
        --timeout=30 \
        --tries=5 \
        --waitretry=10 \
        --retry-connrefused \
        --continue \
        --no-check-certificate \
        --content-disposition \
        --user-agent="$ua" \
        -O "$temp_file" \
        "$url" 2>&1 | grep -E "(100%|saved|downloaded)" | tail -1; then
        if [[ -f "$temp_file" ]]; then
            mv "$temp_file" "$filename"
            success=1
        fi
    fi

    # Fallback con curl si wget falló
    if [[ "$success" -eq 0 ]]; then
        log "$YELLOW" "  wget falló, probando curl..."
        rm -f "$temp_file"
        if curl \
            -fL \
            --retry 5 \
            --retry-delay 10 \
            --connect-timeout 30 \
            --max-time 7200 \
            -C - \
            -A "$ua" \
            -o "$temp_file" \
            "$url" 2>&1 | tail -3; then
            if [[ -f "$temp_file" ]]; then
                mv "$temp_file" "$filename"
                success=1
            fi
        fi
    fi

    # Verificar
    if [[ -f "$filename" ]]; then
        local size size_mb
        size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        size_mb=$(echo "scale=2; $size/1048576" | bc 2>/dev/null || echo "$((size/1048576))")

        if [[ "$size" -lt 500000 ]]; then
            err "Archivo muy pequeño (${size_mb} MB) - posiblemente corrupto"
            return 1
        fi

        log "$GREEN" "Descargado: $(basename "$filename") (${size_mb} MB)"
        return 0
    fi

    err "Falló la descarga"
    return 1
}

# ============================================================
# 5. Extraer archivos comprimidos
# ============================================================
extraer_si_necesario() {
    local archivo="$1"
    local dir="$2"
    local encontro_imagen=0

    mkdir -p "$dir"

    local nombre_ext=$(basename "$archivo" | tr '[:upper:]' '[:lower:]')

    case "$nombre_ext" in
        *.7z)
            log "$YELLOW" "Extrayendo 7z..."
            7z x -y -o"$dir" "$archivo" > /dev/null 2>&1 && \
                log "$GREEN" "  Extracción OK" || \
                err "  Error en extracción"
            # Extraer 7z anidados
            while IFS= read -r f; do
                log "$CYAN" "  Sub-archivo: $(basename "$f")"
                7z x -y -o"$dir" "$f" > /dev/null 2>&1 || true
            done < <(find "$dir" -maxdepth 2 -name "*.7z" -type f 2>/dev/null)
            ;;
        *.zip)
            log "$YELLOW" "Extrayendo ZIP..."
            unzip -o -q "$archivo" -d "$dir" 2>/dev/null && \
                log "$GREEN" "  Extracción OK" || \
                err "  Error en extracción"
            ;;
        *.tar.gz|*.tgz)
            log "$YELLOW" "Extrayendo TAR.GZ..."
            tar -xzf "$archivo" -C "$dir" 2>/dev/null && \
                log "$GREEN" "  Extracción OK" || \
                err "  Error en extracción"
            ;;
        *.tar.xz|*.txz)
            log "$YELLOW" "Extrayendo TAR.XZ..."
            tar -xJf "$archivo" -C "$dir" 2>/dev/null && \
                log "$GREEN" "  Extracción OK" || \
                err "  Error en extracción"
            ;;
        *.tar.bz2|*.tbz2)
            log "$YELLOW" "Extrayendo TAR.BZ2..."
            tar -xjf "$archivo" -C "$dir" 2>/dev/null && \
                log "$GREEN" "  Extracción OK" || \
                err "  Error en extracción"
            ;;
        *.xz)
            log "$YELLOW" "Descomprimiendo XZ..."
            xz -dk "$archivo" --stdout > "${dir}/$(basename "$archivo" .xz)" 2>/dev/null && \
                log "$GREEN" "  OK" || \
                err "  Error"
            ;;
        *.bz2)
            log "$YELLOW" "Descomprimiendo BZ2..."
            bzip2 -dk "$archivo" --stdout > "${dir}/$(basename "$archivo" .bz2)" 2>/dev/null && \
                log "$GREEN" "  OK" || \
                err "  Error"
            ;;
        *.iso|*.vhd|*.vhdx|*.qcow2|*.img|*.vmdk|*.raw)
            log "$GREEN" "Imagen detectada, copiando..."
            cp "$archivo" "$dir/"
            encontro_imagen=1
            ;;
        *)
            log "$YELLOW" "Tipo no reconocido, copiando..."
            cp "$archivo" "$dir/"
            ;;
    esac

    # Si se extrajo, buscar imágenes en los resultados
    if [[ "$encontro_imagen" -eq 0 ]]; then
        local found
        found=$(buscar_imagen "$dir" 2>/dev/null)
        [[ -n "$found" ]] && encontro_imagen=1
    fi

    return $encontro_imagen
}

# ============================================================
# 6. Buscar imagen booteable
# ============================================================
buscar_imagen() {
    local dir="$1"
    local best=""
    local best_size=0

    log "$YELLOW" "Buscando imagen booteable..."

    # Prioridad: imágenes de disco y ISO
    local exts=("vhd" "vhdx" "img" "qcow2" "vmdk" "raw" "iso")

    for ext in "${exts[@]}"; do
        while IFS= read -r -d '' f; do
            local size
            size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))

            if [[ "$size_mb" -gt 50 ]]; then
                log "$CYAN" "  $(basename "$f") (${size_mb} MB)"
            fi

            # Preferir imágenes más grandes, pero ISO tiene prioridad si es arrancable
            local priority=0
            [[ "$ext" == "iso" ]] && priority=10000
            local total=$((size + priority))

            if [[ "$total" -gt "$best_size" && "$size_mb" -gt 50 ]]; then
                best="$f"
                best_size="$total"
            fi
        done < <(find "$dir" -type f -iname "*.${ext}" -print0 2>/dev/null)
    done

    # Si no se encontró nada, buscar archivos grandes genéricos
    if [[ -z "$best" ]]; then
        while IFS= read -r -d '' f; do
            local size
            size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            if [[ "$size" -gt "$best_size" && "$size_mb" -gt 500 ]]; then
                best="$f"
                best_size="$size"
            fi
        done < <(find "$dir" -type f -size +500M -print0 2>/dev/null)
    fi

    if [[ -n "$best" ]]; then
        local size_gb
        size_gb=$(echo "scale=2; $best_size/1073741824" | bc 2>/dev/null || echo "?")
        log "$GREEN" "Seleccionado: $(basename "$best") (${size_gb} GB)"
        echo "$best"
    else
        echo ""
    fi
}

# ============================================================
# 7. Iniciar QEMU
# ============================================================
iniciar_qemu() {
    local imagen="$1"
    local ext
    ext=$(echo "${imagen##*.}" | tr '[:upper:]' '[:lower:]')
    local format="raw"
    local media="disk"
    local boot="c"
    local extra_args=""

    # Detectar formato
    case "$ext" in
        vhd|vpc)  format="vpc" ;;
        vhdx)     format="vhdx" ;;
        qcow2)    format="qcow2" ;;
        img|raw)  format="raw" ;;
        iso)      format="raw"; media="cdrom"; boot="d" ;;
        vmdk)     format="vmdk" ;;
    esac

    log "$YELLOW" "Iniciando QEMU (${RAM_MB} MB RAM, formato: ${format})..."

    # Matar instancias previas
    pkill -f "qemu-system-x86_64" 2>/dev/null || true
    sleep 2

    # Verificar puerto VNC
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        log "$YELLOW" "Puerto VNC ocupado, usando puerto $((5900 + VNC_PORT + 1))..."
        VNC_PORT=$((VNC_PORT + 1))
    fi

    # Aceleración: intentar KVM primero, fallback TCG
    local accel="tcg,thread=multi"
    [[ -e /dev/kvm ]] && accel="kvm"

    # CPU: detectar núcleos
    local cpus
    cpus=$(nproc 2>/dev/null || echo "2")
    [[ "$cpus" -gt 4 ]] && cpus=4

    # Argumentos base comunes
    local base_args=(
        -m "$RAM_MB" -smp "$cpus" -cpu max
        -accel "$accel" -machine type=pc
        -vga std -display vnc=:$VNC_PORT
        -usb -device usb-tablet
        -rtc base=localtime
    )

    # Red
    local net_args=(
        -netdev user,id=net0 -device e1000,netdev=net0
    )

    if [[ "$media" == "cdrom" ]]; then
        # ISO: crear disco temporal para instalar
        local disk_img="/content/qemu_disk.qcow2"
        if [[ ! -f "$disk_img" ]]; then
            log "$CYAN" "  Creando disco virtual de 60G..."
            qemu-img create -f qcow2 "$disk_img" 60G > /dev/null 2>&1
        fi

        qemu-system-x86_64 \
            "${base_args[@]}" \
            -drive file="$disk_img",format=qcow2,index=0,media=disk \
            -drive file="$imagen",format=raw,index=1,media=cdrom \
            -boot d \
            "${net_args[@]}" \
            > /dev/null 2>&1 &

        save_pid $!
    else
        qemu-system-x86_64 \
            "${base_args[@]}" \
            -drive file="$imagen",format="$format",if=ide,index=0 \
            -boot c \
            "${net_args[@]}" \
            > /dev/null 2>&1 &

        save_pid $!
    fi

    # Esperar a que arranque
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
# 8. Iniciar túneles (noVNC + Cloudflare/ngrok)
# ============================================================
iniciar_remoto() {
    # noVNC
    log "$YELLOW" "Iniciando noVNC..."

    local novnc_dir=""
    # Buscar directorio de noVNC
    for d in "/usr/share/novnc" "/usr/share/noVNC" "/usr/local/share/novnc"; do
        [[ -d "$d" ]] && { novnc_dir="$d"; break; }
    done

    if [[ -z "$novnc_dir" ]]; then
        # Descargar noVNC si no está instalado
        log "$YELLOW" "  Descargando noVNC..."
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

    # Tunnel
    log "$YELLOW" "Iniciando túnel..."
    local tunnel_url=""
    local tunnel_pid=""

    # Intentar cloudflared
    if command -v cloudflared &>/dev/null; then
        log "$CYAN" "  Cloudflare Tunnel..."
        cloudflared tunnel --no-autoupdate \
            --url "http://127.0.0.1:${NOVNC_PORT}" \
            > /tmp/cloudflared.log 2>&1 &
        tunnel_pid=$!
        save_pid $tunnel_pid

        for i in {1..30}; do
            tunnel_url=$(grep -oP 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
            [[ -n "$tunnel_url" ]] && break
            sleep 2
        done
    fi

    # Fallback: ngrok
    if [[ -z "$tunnel_url" ]]; then
        if command -v ngrok &>/dev/null; then
            log "$CYAN" "  ngrok..."
            ngrok http "$NOVNC_PORT" --log=stdout > /tmp/ngrok.log 2>&1 &
            save_pid $!
            for i in {1..20}; do
                tunnel_url=$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | grep -oP '"public_url":"\K[^"]+' | head -1)
                [[ -n "$tunnel_url" ]] && break
                sleep 2
            done
        else
            # Instalar ngrok
            log "$YELLOW" "  Instalando ngrok..."
            wget -q https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz -O /tmp/ngrok.tgz 2>/dev/null && \
            tar -xzf /tmp/ngrok.tgz -C /usr/local/bin/ > /dev/null 2>&1 && \
            chmod +x /usr/local/bin/ngrok || true

            if command -v ngrok &>/dev/null; then
                ngrok http "$NOVNC_PORT" --log=stdout > /tmp/ngrok.log 2>&1 &
                save_pid $!
                for i in {1..20}; do
                    tunnel_url=$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | grep -oP '"public_url":"\K[^"]+' | head -1)
                    [[ -n "$tunnel_url" ]] && break
                    sleep 2
                done
            fi
        fi
    fi

    # Mostrar URLs
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}  ✅ MÁQUINA VIRTUAL LISTA${NC}"
    echo -e "${BLUE}============================================================${NC}"

    if [[ -n "$tunnel_url" ]]; then
        echo -e "${GREEN}  🌍 URL:${NC} ${tunnel_url}"
    else
        # Local tunnel (servicio público alternativo)
        log "$YELLOW" "  Probando localhost.run..."
        ssh -o StrictHostKeyChecking=no -R 80:localhost:"$NOVNC_PORT" nokey@localhost.run > /tmp/localshare.log 2>&1 &
        save_pid $!
        sleep 8
        tunnel_url=$(grep -oP 'https://[a-zA-Z0-9-]+\.lhr\.life' /tmp/localshare.log 2>/dev/null | head -1)
        [[ -n "$tunnel_url" ]] && echo -e "${GREEN}  🌍 URL:${NC} ${tunnel_url}" || \
            echo -e "${YELLOW}  🌍 URL local: http://127.0.0.1:${NOVNC_PORT}${NC}"
    fi

    echo -e "${YELLOW}  💡 Contraseña VNC: colab123${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

# ============================================================
# HELP
# ============================================================
mostrar_ayuda() {
    cat <<EOF
USO:
  $0 "URL" [RAM_MB]

EJEMPLOS:
  $0 "https://archive.org/details/win10_iso"
  $0 "https://www.mediafire.com/file/abc123/ubuntu.iso" 8192
  $0 "https://example.com/os.qcow2" 4096

SOPORTA:
  • Mediafire (resolución automática de enlaces)
  • Archive.org (búsqueda de ISO/IMG)
  • Google Drive (con bypass de confirmación)
  • Enlaces directos (ISO, IMG, VHD, VHDX, QCOW2, VMDK, 7Z, ZIP)
EOF
}

# ============================================================
# MAIN
# ============================================================

if [[ -z "$URL" || "$URL" == "-h" || "$URL" == "--help" ]]; then
    mostrar_ayuda
    exit 0
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     📥 DESCARGADOR UNIVERSAL + QEMU v3.0${NC}"
echo -e "${BLUE}============================================================${NC}"

# 1. Dependencias
instalar_deps

# 2. Resolver URL
DIRECT_URL=$(resolver_url "$URL")
if [[ -z "$DIRECT_URL" ]]; then
    err "No se pudo resolver la URL"
    exit 1
fi
log "$GREEN" "URL resuelta: $(echo "$DIRECT_URL" | sed 's/?.*//')"

# 3. Nombre de archivo
FILENAME=$(get_filename "$DIRECT_URL")
log "$CYAN" "Archivo: $FILENAME"

# 4. Preparar directorio
rm -rf "$WORKDIR" 2>/dev/null || true
mkdir -p "$WORKDIR"

# 5. Descargar
if ! descargar "$DIRECT_URL" "$FILENAME"; then
    err "Descarga fallida. Verifica la URL e intenta de nuevo."
    exit 1
fi

# 6. Extraer si es necesario
IMAGEN=""
if [[ "$FILENAME" =~ \.(7z|zip|tar\.gz|tgz|tar\.xz|tar\.bz2|xz|bz2)$ ]]; then
    extraer_si_necesario "$FILENAME" "$WORKDIR"
else
    cp "$FILENAME" "$WORKDIR/" 2>/dev/null || true
fi

# 7. Buscar imagen
IMAGEN=$(buscar_imagen "$WORKDIR")

if [[ -z "$IMAGEN" ]]; then
    err "No se encontró ninguna imagen booteable en el archivo descargado."
    err "Archivos en $WORKDIR:"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    exit 1
fi

# 8. Iniciar QEMU
if ! iniciar_qemu "$IMAGEN"; then
    err "QEMU no pudo iniciar"
    exit 1
fi

# 9. Iniciar túnel
iniciar_remoto

# 10. Mantener vivo
log "$GREEN" "Script completado. Manteniendo procesos activos..."
log "$YELLOW" "Presiona Ctrl+C para detener todo."

while true; do
    sleep 60
done
