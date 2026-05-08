#!/bin/bash

# ============================================================
# DESCARGADOR UNIVERSAL + QEMU BOOT
# Uso: ./download_and_boot.sh "URL_DEL_ARCHIVO" [RAM_MB]
# Soporta: Mediafire (todos los formatos), Google Drive, Archive.org, enlaces directos
# Formatos: ISO, 7z, VHD, VHDX, QCOW2, IMG, ZIP
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

URL="$1"
RAM_MB="${2:-4096}"
VNC_PORT=7
NOVNC_PORT=6081
WORKDIR="/content/qemu_work"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     📥 DESCARGADOR UNIVERSAL + QEMU${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ============================================================
# Función: Instalar dependencias
# ============================================================
instalar_deps() {
    echo -e "${YELLOW}🔧 Instalando herramientas...${NC}"
    sudo rm -f /etc/apt/sources.list.d/*.list 2>/dev/null
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq --fix-missing \
        qemu-system-x86 qemu-utils novnc websockify wget p7zip-full > /dev/null 2>&1
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        echo -e "${RED}❌ QEMU no se instaló.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Herramientas listas.${NC}"
}

# ============================================================
# Función: Resolver URL (detectar tipo y obtener enlace directo)
# ============================================================
resolver_url() {
    local url="$1"
    
    echo -e "${YELLOW}🔍 Analizando URL...${NC}"
    
    # Caso 1: Ya es un enlace directo (contiene extensiones conocidas)
    if [[ "$url" =~ \.(iso|7z|vhd|vhdx|qcow2|img|vmdk|zip|tgz|tar\.gz)(\?|$) ]] || [[ "$url" =~ /download/ ]]; then
        echo -e "${GREEN}✅ Enlace directo detectado.${NC}"
        echo "$url"
        return
    fi
    
    # Caso 2: Archive.org
    if [[ "$url" == *"archive.org"* ]]; then
        echo -e "${GREEN}✅ Archive.org detectado (enlace permanente).${NC}"
        echo "$url"
        return
    fi
    
    # Caso 3: Mediafire (TODOS los formatos)
    if [[ "$url" == *"mediafire.com"* ]]; then
        echo -e "${CYAN}   Detectado: Mediafire${NC}"
        
        # Extraer ID del archivo (soporta múltiples formatos de URL)
        local file_id=""
        
        # Formato: /file/ID/nombre/file
        file_id=$(echo "$url" | grep -oP '/file/\K[^/]+' | head -1)
        
        # Formato: /file/ID?dkey=...
        if [ -z "$file_id" ]; then
            file_id=$(echo "$url" | grep -oP '/file/\K[^/?]+' | head -1)
        fi
        
        if [ -z "$file_id" ]; then
            echo -e "${RED}❌ No se pudo extraer ID de Mediafire.${NC}"
            echo "$url"
            return
        fi
        
        echo -e "${CYAN}   ID del archivo: $file_id${NC}"
        
        # Construir URL de la página del archivo
        local page_url="https://www.mediafire.com/file/${file_id}/"
        
        # Descargar la página HTML
        local html=$(wget -qO- --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$page_url" 2>/dev/null)
        
        # Buscar enlace directo con múltiples patrones
        local direct=""
        
        # Patrón 1: href con download
        direct=$(echo "$html" | grep -oP 'href="\Khttps?://download\d+\.mediafire\.com/[^"]+' | head -1)
        
        # Patrón 2: kNO (JavaScript)
        if [ -z "$direct" ]; then
            direct=$(echo "$html" | grep -oP 'kNO\s*=\s*"\K[^"]+' | head -1)
        fi
        
        # Patrón 3: Cualquier URL de descarga
        if [ -z "$direct" ]; then
            direct=$(echo "$html" | grep -oP 'https?://download\d+\.mediafire\.com/[^"'\'' )]+' | head -1)
        fi
        
        if [ -n "$direct" ]; then
            direct=$(echo "$direct" | sed 's/&amp;/\&/g')
            echo -e "${GREEN}✅ Enlace directo extraído.${NC}"
            echo "$direct"
            return
        else
            echo -e "${YELLOW}⚠️  No se pudo extraer enlace directo.${NC}"
            echo -e "${YELLOW}   Intentando con la URL original...${NC}"
            echo "$url"
            return
        fi
    fi
    
    # Caso 4: Google Drive
    if [[ "$url" == *"drive.google.com"* ]]; then
        echo -e "${CYAN}   Detectado: Google Drive${NC}"
        local file_id=$(echo "$url" | grep -oP '/d/\K[^/]+' || echo "$url" | grep -oP 'id=\K[^&]+')
        if [ -n "$file_id" ]; then
            echo "https://drive.google.com/uc?export=download&id=$file_id"
            return
        fi
    fi
    
    # Caso 5: No se pudo resolver
    echo -e "${YELLOW}⚠️  Tipo de URL no reconocido. Usando URL original.${NC}"
    echo "$url"
}

# ============================================================
# Función: Obtener nombre de archivo
# ============================================================
get_filename() {
    local url="$1"
    local filename=""
    
    # Intentar extraer nombre de la URL
    filename=$(echo "$url" | grep -oP '[^/]+(?=\?|$)' | tail -1)
    
    # Decodificar caracteres URL
    filename=$(python3 -c "
import urllib.parse, sys
try:
    print(urllib.parse.unquote('$filename'))
except:
    print('$filename')
" 2>/dev/null || echo "$filename")
    
    # Si no se pudo obtener, usar nombre genérico
    if [ -z "$filename" ] || [ ${#filename} -lt 4 ]; then
        filename="downloaded_file"
    fi
    
    echo "$filename"
}

# ============================================================
# Función: Descargar archivo
# ============================================================
descargar() {
    local url="$1"
    local filename="$2"
    
    # Verificar si ya existe y es válido
    if [ -f "$filename" ]; then
        local size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        if [ "$size" -gt 1000000 ]; then
            local size_mb=$(echo "scale=2; $size/1048576" | bc)
            echo -e "${GREEN}✅ Archivo ya existe: ${size_mb} MB${NC}"
            return 0
        else
            rm -f "$filename"
        fi
    fi
    
    echo -e "${YELLOW}📥 Descargando: $filename${NC}"
    wget -q --show-progress --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -O "$filename" "$url"
    
    if [ -f "$filename" ]; then
        local size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        local size_mb=$(echo "scale=2; $size/1048576" | bc)
        
        if [ "$size" -lt 500000 ]; then
            echo -e "${RED}❌ Archivo muy pequeño (${size_mb} MB). Descarga fallida.${NC}"
            echo -e "${YELLOW}   Posible causa: enlace expirado o requiere cookies.${NC}"
            return 1
        fi
        
        echo -e "${GREEN}✅ Descargado: ${size_mb} MB${NC}"
        return 0
    else
        echo -e "${RED}❌ Error en la descarga.${NC}"
        return 1
    fi
}

# ============================================================
# Función: Extraer archivos comprimidos
# ============================================================
extraer_si_necesario() {
    local archivo="$1"
    local dir="$2"
    
    mkdir -p "$dir"
    
    case "$archivo" in
        *.7z)
            echo -e "${YELLOW}📦 Extrayendo 7z...${NC}"
            7z x -y -o"$dir" "$archivo" > /dev/null 2>&1
            
            # Buscar y extraer 7z anidados
            local anidados=$(find "$dir" -maxdepth 2 -name "*.7z" -type f 2>/dev/null)
            if [ -n "$anidados" ]; then
                while IFS= read -r f; do
                    echo -e "${CYAN}   Extrayendo anidado: $(basename "$f")${NC}"
                    7z x -y -o"$dir" "$f" > /dev/null 2>&1
                done <<< "$anidados"
            fi
            ;;
        *.zip)
            echo -e "${YELLOW}📦 Extrayendo ZIP...${NC}"
            unzip -o -q "$archivo" -d "$dir"
            ;;
        *.iso|*.vhd|*.vhdx|*.qcow2|*.img|*.vmdk)
            echo -e "${GREEN}✅ Archivo de disco/imagen detectado.${NC}"
            cp "$archivo" "$dir/"
            ;;
        *)
            echo -e "${YELLOW}⚠️  Tipo desconocido. Copiando al directorio de trabajo...${NC}"
            cp "$archivo" "$dir/"
            ;;
    esac
}

# ============================================================
# Función: Buscar imagen booteable
# ============================================================
buscar_imagen() {
    local dir="$1"
    local best=""
    local best_size=0
    
    echo -e "${YELLOW}🔍 Buscando imagen booteable...${NC}"
    
    # Buscar por extensiones conocidas
    for ext in vhd vhdx img qcow2 vmdk raw iso; do
        while IFS= read -r f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            
            if [ "$size_mb" -gt 50 ]; then
                echo -e "   📄 $(basename "$f") (${size_mb} MB) [.${ext}]"
            fi
            
            if [ "$size" -gt "$best_size" ] && [ "$size_mb" -gt 50 ]; then
                best="$f"
                best_size="$size"
            fi
        done < <(find "$dir" -type f -iname "*.$ext" 2>/dev/null)
    done
    
    # Si no encontró por extensión, buscar archivos grandes (>500 MB)
    if [ -z "$best" ]; then
        echo -e "${CYAN}   Buscando archivos grandes sin extensión conocida...${NC}"
        while IFS= read -r f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            
            if [ "$size" -gt "$best_size" ] && [ "$size_mb" -gt 500 ]; then
                echo -e "   📄 $(basename "$f") (${size_mb} MB)"
                best="$f"
                best_size="$size"
            fi
        done < <(find "$dir" -type f 2>/dev/null)
    fi
    
    if [ -n "$best" ]; then
        local size_gb=$(echo "scale=2; $best_size/1073741824" | bc 2>/dev/null || echo "?")
        echo -e "${GREEN}✅ Imagen seleccionada: $(basename "$best") (${size_gb} GB)${NC}"
        echo "$best"
    else
        echo ""
    fi
}

# ============================================================
# Función: Iniciar QEMU con la imagen
# ============================================================
iniciar_qemu() {
    local imagen="$1"
    local ext=$(echo "${imagen##*.}" | tr '[:upper:]' '[:lower:]')
    
    # Determinar formato y tipo
    local format=""
    local media="disk"
    local boot="c"
    
    case "$ext" in
        vhd|vpc)  format="vpc" ;;
        vhdx)     format="vhdx" ;;
        qcow2)    format="qcow2" ;;
        img|raw)  format="raw" ;;
        iso)
            format="raw"
            media="cdrom"
            boot="d"
            ;;
        *) format="raw" ;;
    esac
    
    echo -e "${YELLOW}🚀 Iniciando QEMU (formato: $format, tipo: $media)...${NC}"
    
    # Limpiar procesos anteriores
    pkill -9 qemu 2>/dev/null
    sudo fuser -k $((5900 + VNC_PORT))/tcp 2>/dev/null
    sleep 2
    
    if [ "$media" = "cdrom" ]; then
        # Es una ISO: necesita disco duro virtual
        local disk="/content/qemu_disk.qcow2"
        if [ ! -f "$disk" ]; then
            echo -e "${CYAN}   Creando disco virtual de 60 GB...${NC}"
            qemu-img create -f qcow2 "$disk" 60G > /dev/null 2>&1
        fi
        
        qemu-system-x86_64 \
            -m "$RAM_MB" -smp 2 -cpu max \
            -accel tcg,thread=multi -machine type=pc \
            -vga std -display vnc=:$VNC_PORT \
            -drive file="$disk",format=qcow2,index=0,media=disk \
            -drive file="$imagen",format=raw,index=1,media=cdrom \
            -boot d -usb -device usb-tablet \
            -rtc base=localtime \
            -netdev user,id=net0 -device e1000,netdev=net0 \
            > /dev/null 2>&1 &
    else
        # Imagen de disco: arranque directo
        qemu-system-x86_64 \
            -m "$RAM_MB" -smp 2 -cpu max \
            -accel tcg,thread=multi -machine type=pc \
            -vga std -display vnc=:$VNC_PORT \
            -drive file="$imagen",format="$format",if=ide,index=0 \
            -boot c -usb -device usb-tablet \
            -rtc base=localtime \
            -netdev user,id=net0 -device e1000,netdev=net0 \
            > /dev/null 2>&1 &
    fi
    
    sleep 8
    
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        echo -e "${GREEN}✅ QEMU corriendo en puerto 590${VNC_PORT}${NC}"
        return 0
    else
        echo -e "${RED}❌ QEMU no inició.${NC}"
        return 1
    fi
}

# ============================================================
# Función: Iniciar acceso remoto (noVNC + Cloudflare)
# ============================================================
iniciar_remoto() {
    # Limpiar
    pkill websockify 2>/dev/null
    pkill cloudflared 2>/dev/null
    
    echo -e "${YELLOW}🌐 Iniciando noVNC...${NC}"
    websockify --web /usr/share/novnc $NOVNC_PORT localhost:590${VNC_PORT} > /dev/null 2>&1 &
    sleep 2
    
    echo -e "${YELLOW}⛅ Creando túnel Cloudflare...${NC}"
    
    if ! command -v cloudflared &> /dev/null; then
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cf.deb
        sudo dpkg -i /tmp/cf.deb > /dev/null 2>&1
    fi
    
    cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$NOVNC_PORT > /tmp/cf.log 2>&1 &
    
    echo -e "${YELLOW}⏳ Esperando URL pública...${NC}"
    for i in {1..25}; do
        URL=$(grep -oP 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cf.log 2>/dev/null | head -1)
        if [ -n "$URL" ]; then
            echo ""
            echo -e "${BLUE}============================================================${NC}"
            echo -e "${GREEN}🌍 URL DE ACCESO:${NC}"
            echo -e "${GREEN}   $URL${NC}"
            echo -e "${BLUE}============================================================${NC}"
            echo -e "${YELLOW}💡 Contraseña VNC: colab123${NC}"
            echo ""
            return 0
        fi
        sleep 2
    done
    
    echo -e "${YELLOW}⚠️  URL no encontrada aún. Revisa: cat /tmp/cf.log${NC}"
}

# ============================================================
# MAIN
# ============================================================

if [ -z "$URL" ]; then
    echo -e "${RED}❌ Uso: $0 \"URL_DEL_ARCHIVO\" [RAM_MB]${NC}"
    echo -e "${YELLOW}   Ejemplo: $0 \"https://www.mediafire.com/file/xxx/archivo.7z/file\" 4096${NC}"
    exit 1
fi

# Paso 1: Instalar
instalar_deps

# Paso 2: Resolver URL
DIRECT_URL=$(resolver_url "$URL")

# Paso 3: Obtener nombre de archivo
FILENAME=$(get_filename "$DIRECT_URL")
echo -e "${CYAN}📄 Archivo: $FILENAME${NC}"

# Paso 4: Crear directorio de trabajo
rm -rf "$WORKDIR" 2>/dev/null
mkdir -p "$WORKDIR"

# Paso 5: Descargar
if ! descargar "$DIRECT_URL" "$FILENAME"; then
    echo -e "${RED}❌ Falló la descarga. Verifica la URL.${NC}"
    exit 1
fi

# Paso 6: Extraer si es necesario
extraer_si_necesario "$FILENAME" "$WORKDIR"

# Paso 7: Buscar imagen booteable
IMAGEN=$(buscar_imagen "$WORKDIR")

if [ -z "$IMAGEN" ]; then
    echo -e "${RED}❌ No se encontró ninguna imagen booteable.${NC}"
    echo -e "${YELLOW}   Contenido del directorio de trabajo:${NC}"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    exit 1
fi

# Paso 8: Iniciar QEMU
if ! iniciar_qemu "$IMAGEN"; then
    echo -e "${RED}❌ QEMU no pudo iniciar.${NC}"
    exit 1
fi

# Paso 9: Acceso remoto
iniciar_remoto

echo -e "${GREEN}✅ Todo listo. La VM está corriendo.${NC}"
echo -e "${YELLOW}   Presiona Ctrl+C para detener.${NC}"

# Mantener vivo
while true; do
    sleep 60
done
