#!/bin/bash

# ============================================================
# QEMU UNIVERSAL BOOT v3.0 - Detección por extensión + MIME
# Uso: ./boot_any.sh "URL" [RAM_MB]
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

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     📥 QEMU UNIVERSAL BOOT v3.0${NC}"
echo -e "${BLUE}============================================================${NC}"

[ -z "$URL" ] && { echo -e "${RED}❌ Uso: $0 \"URL\" [RAM]${NC}"; exit 1; }

# ============================================================
# 1. Instalar dependencias
# ============================================================
echo -e "${YELLOW}🔧 Instalando herramientas...${NC}"
sudo rm -f /etc/apt/sources.list.d/*.list 2>/dev/null
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq --fix-missing \
    qemu-system-x86 qemu-utils novnc websockify wget p7zip-full file > /dev/null 2>&1

if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo -e "${RED}❌ QEMU no se instaló.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Herramientas listas.${NC}"

# ============================================================
# 2. Descargar archivo
# ============================================================
FILENAME="/content/downloaded_file"
rm -f "$FILENAME" 2>/dev/null

echo -e "${YELLOW}📥 Descargando...${NC}"
wget -q --show-progress --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
    -O "$FILENAME" "$URL"

if [ ! -f "$FILENAME" ] || [ $(stat -c%s "$FILENAME" 2>/dev/null || echo 0) -lt 100000 ]; then
    echo -e "${RED}❌ Descarga fallida o archivo muy pequeño.${NC}"
    exit 1
fi

SIZE_MB=$(echo "scale=2; $(stat -c%s "$FILENAME")/1048576" | bc)
echo -e "${GREEN}✅ Descargado: ${SIZE_MB} MB${NC}"

# ============================================================
# 3. Detectar tipo real del archivo
# ============================================================
MIME_TYPE=$(file -b --mime-type "$FILENAME" 2>/dev/null)
MIME_DESC=$(file -b "$FILENAME" 2>/dev/null)
EXT=$(echo "$FILENAME" | grep -oP '\.\K[^.]+$' | tr '[:upper:]' '[:lower:]')

echo -e "${CYAN}📁 Tipo: $MIME_DESC${NC}"

# ============================================================
# 4. Extraer si es comprimido
# ============================================================
WORKDIR="/content/extracted"
rm -rf "$WORKDIR" 2>/dev/null

if [ "$EXT" = "7z" ] || echo "$MIME_DESC" | grep -qi "7-zip"; then
    echo -e "${YELLOW}📦 Extrayendo 7z...${NC}"
    mkdir -p "$WORKDIR"
    7z x -y -o"$WORKDIR" "$FILENAME" > /dev/null 2>&1
    
    # Extraer anidados
    find "$WORKDIR" -maxdepth 3 \( -name "*.7z" -o -name "*.zip" \) -type f 2>/dev/null | while read f; do
        echo -e "${CYAN}   Extrayendo: $(basename "$f")${NC}"
        7z x -y -o"$WORKDIR" "$f" > /dev/null 2>&1
    done
elif [ "$EXT" = "zip" ] || echo "$MIME_DESC" | grep -qi "zip archive"; then
    echo -e "${YELLOW}📦 Extrayendo ZIP...${NC}"
    mkdir -p "$WORKDIR"
    unzip -o -q "$FILENAME" -d "$WORKDIR"
elif echo "$MIME_TYPE" | grep -qE "iso9660|x-cd-image" || echo "$MIME_DESC" | grep -qiE "ISO|bootable|CD-ROM"; then
    echo -e "${GREEN}✅ ISO detectada directamente.${NC}"
    WORKDIR="/content"
elif echo "$MIME_DESC" | grep -qiE "VHD|Virtual Hard Disk|QCOW2|QEMU"; then
    echo -e "${GREEN}✅ Imagen de disco detectada directamente.${NC}"
    WORKDIR="/content"
else
    echo -e "${YELLOW}⚠️  Tipo desconocido. Usando como imagen.${NC}"
    WORKDIR="/content"
fi

# ============================================================
# 5. Buscar imagen booteable (por extensión + tipo MIME)
# ============================================================
echo -e "${YELLOW}🔍 Buscando imagen booteable...${NC}"
IMAGEN=""
BEST=0

# Buscar por extensión
for ext in vhd vhdx img qcow2 vmdk raw iso; do
    while IFS= read -r f; do
        SZ=$(stat -c%s "$f" 2>/dev/null || echo 0)
        SM=$((SZ/1048576))
        [ "$SM" -gt 50 ] && echo -e "   📄 $(basename "$f") (${SM} MB) [.$ext]"
        [ "$SZ" -gt "$BEST" ] && [ "$SM" -gt 50 ] && { IMAGEN="$f"; BEST="$SZ"; }
    done < <(find "$WORKDIR" -type f -iname "*.$ext" 2>/dev/null)
done

# Si no encontró, buscar por tipo MIME
if [ -z "$IMAGEN" ]; then
    echo -e "${CYAN}   Buscando por tipo MIME...${NC}"
    while IFS= read -r f; do
        SZ=$(stat -c%s "$f" 2>/dev/null || echo 0)
        SM=$((SZ/1048576))
        
        if [ "$SM" -gt 50 ] && [ "$SZ" -gt "$BEST" ]; then
            MIME_F=$(file -b --mime-type "$f" 2>/dev/null)
            MIME_D=$(file -b "$f" 2>/dev/null)
            
            # Detectar ISO, VHD, QCOW2, imágenes de disco
            if echo "$MIME_F" | grep -qE "iso9660|x-cd-image" || \
               echo "$MIME_D" | grep -qiE "ISO|bootable|CD-ROM|VHD|Virtual Hard Disk|QCOW2|QEMU|disk image"; then
                echo -e "   📄 $(basename "$f") (${SM} MB) [$MIME_D]"
                IMAGEN="$f"
                BEST="$SZ"
            fi
        fi
    done < <(find "$WORKDIR" -type f 2>/dev/null)
fi

# Último recurso: el archivo descargado original
if [ -z "$IMAGEN" ] && [ -f "$FILENAME" ] && [ $(stat -c%s "$FILENAME") -gt 50000000 ]; then
    echo -e "${CYAN}   Usando archivo original como imagen...${NC}"
    IMAGEN="$FILENAME"
    BEST=$(stat -c%s "$FILENAME")
fi

[ -z "$IMAGEN" ] && { 
    echo -e "${RED}❌ No se encontró ninguna imagen booteable.${NC}"
    echo -e "${YELLOW}   Archivos encontrados:${NC}"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    exit 1
}

GB=$(echo "scale=2; $BEST/1073741824" | bc 2>/dev/null || echo "?")
echo -e "${GREEN}✅ Imagen: $(basename "$IMAGEN") (${GB} GB)${NC}"

# ============================================================
# 6. Determinar formato y arrancar QEMU
# ============================================================
IMAGEN_EXT=$(echo "${IMAGEN##*.}" | tr '[:upper:]' '[:lower:]')
IMAGEN_MIME=$(file -b --mime-type "$IMAGEN" 2>/dev/null)
IS_ISO=0

# Detectar si es ISO por extensión o MIME
if [ "$IMAGEN_EXT" = "iso" ] || echo "$IMAGEN_MIME" | grep -qE "iso9660|x-cd-image" || echo "$(file -b "$IMAGEN")" | grep -qi "ISO|bootable|CD-ROM"; then
    IS_ISO=1
    FORMAT="raw"
else
    case "$IMAGEN_EXT" in
        vhd)  FORMAT="vpc" ;;
        vhdx) FORMAT="vhdx" ;;
        qcow2) FORMAT="qcow2" ;;
        img|raw) FORMAT="raw" ;;
        *) FORMAT="raw" ;;
    esac
fi

# Limpiar puertos
pkill -9 qemu 2>/dev/null
sudo fuser -k 5907/tcp 2>/dev/null
sudo fuser -k 6081/tcp 2>/dev/null
sleep 2

# Arrancar QEMU
echo -e "${YELLOW}🚀 Iniciando QEMU...${NC}"

if [ "$IS_ISO" = "1" ]; then
    DISK="/content/qemu_disk.qcow2"
    if [ ! -f "$DISK" ]; then
        echo -e "${CYAN}   Creando disco virtual de 60 GB...${NC}"
        qemu-img create -f qcow2 "$DISK" 60G > /dev/null 2>&1
    fi
    qemu-system-x86_64 \
        -m "$RAM_MB" -smp 2 -cpu max \
        -accel tcg,thread=multi -machine type=pc \
        -vga std -display vnc=:$VNC_PORT \
        -drive file="$DISK",format=qcow2,index=0,media=disk \
        -drive file="$IMAGEN",format=raw,index=1,media=cdrom \
        -boot d -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
else
    qemu-system-x86_64 \
        -m "$RAM_MB" -smp 2 -cpu max \
        -accel tcg,thread=multi -machine type=pc \
        -vga std -display vnc=:$VNC_PORT \
        -drive file="$IMAGEN",format="$FORMAT",if=ide,index=0 \
        -boot c -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
fi

sleep 8

if ! ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
    echo -e "${RED}❌ QEMU no inició.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ QEMU corriendo en puerto 590${VNC_PORT}.${NC}"

# ============================================================
# 7. Acceso remoto (noVNC + Cloudflare)
# ============================================================
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
URL_OUT=""
for i in {1..30}; do
    URL_OUT=$(grep -oP 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cf.log 2>/dev/null | head -1)
    [ -n "$URL_OUT" ] && break
    sleep 2
done

if [ -n "$URL_OUT" ]; then
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}🌍 URL DE ACCESO:${NC}"
    echo -e "${GREEN}   $URL_OUT${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${YELLOW}💡 Contraseña VNC: colab123${NC}"
    echo ""
else
    echo -e "${YELLOW}⚠️  URL no encontrada aún. Revisa: cat /tmp/cf.log${NC}"
fi

echo -e "${GREEN}✅ Todo listo. La VM está corriendo.${NC}"
echo -e "${YELLOW}   Presiona Ctrl+C para detener.${NC}"

# Mantener vivo
while true; do
    sleep 60
done
