#!/bin/bash

# ============================================================
# QEMU UNIVERSAL BOOT - Simplicidad máxima
# Uso: ./boot_any.sh "URL" [RAM_MB]
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

URL="$1"
RAM_MB="${2:-4096}"
VNC_PORT=7
NOVNC_PORT=6081

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     📥 QEMU UNIVERSAL BOOT${NC}"
echo -e "${BLUE}============================================================${NC}"

[ -z "$URL" ] && { echo -e "${RED}❌ Uso: $0 \"URL\" [RAM]${NC}"; exit 1; }

# Instalar
echo -e "${YELLOW}🔧 Instalando...${NC}"
sudo rm -f /etc/apt/sources.list.d/*.list 2>/dev/null
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq qemu-system-x86 qemu-utils novnc websockify wget p7zip-full > /dev/null 2>&1

# Nombre de archivo simple
FILENAME="downloaded_file"
echo "FILE=$FILENAME" > /tmp/qemu_info.txt

# Descargar
echo -e "${YELLOW}📥 Descargando...${NC}"
wget -q --show-progress -O "$FILENAME" --user-agent="Mozilla/5.0" "$URL"

if [ ! -f "$FILENAME" ] || [ $(stat -c%s "$FILENAME") -lt 100000 ]; then
    echo -e "${RED}❌ Descarga fallida.${NC}"
    exit 1
fi

SIZE_MB=$(echo "scale=2; $(stat -c%s "$FILENAME")/1048576" | bc)
echo -e "${GREEN}✅ Descargado: ${SIZE_MB} MB${NC}"

# Detectar tipo
EXT=$(echo "$FILENAME" | grep -oP '\.\K[^.]+$' | tr '[:upper:]' '[:lower:]')

# Extraer si es 7z/zip
if [ "$EXT" = "7z" ] || [ "$EXT" = "zip" ]; then
    echo -e "${YELLOW}📦 Extrayendo...${NC}"
    mkdir -p extracted
    7z x -y -oextracted "$FILENAME" > /dev/null 2>&1
    # Extraer anidados
    find extracted -maxdepth 2 -name "*.7z" -o -name "*.zip" | while read f; do
        7z x -y -oextracted "$f" > /dev/null 2>&1
    done
    WORKDIR="extracted"
else
    WORKDIR="."
fi

# Buscar imagen
echo -e "${YELLOW}🔍 Buscando imagen...${NC}"
IMAGEN=""
BEST=0
for ext in vhd vhdx img qcow2 vmdk raw iso; do
    while IFS= read -r f; do
        SZ=$(stat -c%s "$f" 2>/dev/null || echo 0)
        SM=$((SZ/1048576))
        [ "$SM" -gt 50 ] && echo -e "   📄 $(basename "$f") (${SM} MB)"
        [ "$SZ" -gt "$BEST" ] && [ "$SM" -gt 50 ] && { IMAGEN="$f"; BEST="$SZ"; }
    done < <(find "$WORKDIR" -type f -iname "*.$ext" 2>/dev/null)
done

[ -z "$IMAGEN" ] && { echo -e "${RED}❌ No se encontró imagen.${NC}"; exit 1; }

echo -e "${GREEN}✅ Imagen: $(basename "$IMAGEN") ($(echo "scale=2; $BEST/1073741824"|bc) GB)${NC}"

# Determinar formato
IMAGEN_EXT=$(echo "${IMAGEN##*.}" | tr '[:upper:]' '[:lower:]')
case "$IMAGEN_EXT" in
    vhd)  FORMAT="vpc" ;;
    qcow2) FORMAT="qcow2" ;;
    iso)  FORMAT="raw"; IS_ISO=1 ;;
    *)    FORMAT="raw" ;;
esac

# Limpiar puertos
pkill -9 qemu 2>/dev/null
sudo fuser -k 5907/tcp 2>/dev/null
sudo fuser -k 6081/tcp 2>/dev/null
sleep 2

# Arrancar QEMU
echo -e "${YELLOW}🚀 Iniciando QEMU...${NC}"

if [ "$IS_ISO" = "1" ]; then
    DISK="/content/qemu_disk.qcow2"
    [ ! -f "$DISK" ] && qemu-img create -f qcow2 "$DISK" 60G > /dev/null 2>&1
    qemu-system-x86_64 -m "$RAM_MB" -smp 2 -cpu max -accel tcg,thread=multi \
        -machine type=pc -vga std -display vnc=:$VNC_PORT \
        -drive file="$DISK",format=qcow2,index=0,media=disk \
        -drive file="$IMAGEN",format=raw,index=1,media=cdrom \
        -boot d -usb -device usb-tablet -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 > /dev/null 2>&1 &
else
    qemu-system-x86_64 -m "$RAM_MB" -smp 2 -cpu max -accel tcg,thread=multi \
        -machine type=pc -vga std -display vnc=:$VNC_PORT \
        -drive file="$IMAGEN",format="$FORMAT",if=ide,index=0 \
        -boot c -usb -device usb-tablet -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 > /dev/null 2>&1 &
fi

sleep 8

if ! ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
    echo -e "${RED}❌ QEMU no inició.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ QEMU corriendo.${NC}"

# noVNC
echo -e "${YELLOW}🌐 noVNC...${NC}"
pkill websockify 2>/dev/null
websockify --web /usr/share/novnc $NOVNC_PORT localhost:590${VNC_PORT} > /dev/null 2>&1 &
sleep 2

# Cloudflare
echo -e "${YELLOW}⛅ Cloudflare...${NC}"
pkill cloudflared 2>/dev/null
command -v cloudflared &> /dev/null || { wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cf.deb; sudo dpkg -i /tmp/cf.deb > /dev/null 2>&1; }
cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$NOVNC_PORT > /tmp/cf.log 2>&1 &

# Esperar URL
for i in {1..25}; do
    URL_OUT=$(grep -oP 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cf.log 2>/dev/null | head -1)
    [ -n "$URL_OUT" ] && break
    sleep 2
done

if [ -n "$URL_OUT" ]; then
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}🌍 URL: $URL_OUT${NC}"
    echo -e "${BLUE}============================================================${NC}"
else
    echo -e "${YELLOW}⚠️  URL no encontrada.${NC}"
fi

echo -e "${GREEN}✅ Listo.${NC}"
while true; do sleep 60; done
