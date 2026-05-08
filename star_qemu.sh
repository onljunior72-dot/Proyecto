#!/bin/bash

# ============================================================
# EJECUTOR QEMU - Instala, configura y arranca la VM
# Uso: ./start_qemu.sh [RAM_MB]
# Lee /content/qemu_info.txt para obtener la imagen
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RAM_MB="${1:-4096}"
VNC_PORT=7
NOVNC_PORT=6081
INFO_FILE="/content/qemu_info.txt"

banner() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}     🚀 QEMU WINDOWS STARTER${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

instalar_todo() {
    echo -e "${YELLOW}🔧 Instalando QEMU + VNC + Cloudflare...${NC}"
    sudo rm -f /etc/apt/sources.list.d/*.list 2>/dev/null
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq --fix-missing \
        qemu-system-x86 qemu-utils novnc websockify wget > /dev/null 2>&1
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        echo -e "${RED}❌ QEMU no se instaló.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ QEMU instalado.${NC}"
}

leer_info() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}❌ No se encontró $INFO_FILE${NC}"
        echo -e "${YELLOW}   Ejecuta primero analyze_7z.sh${NC}"
        exit 1
    fi
    
    # Leer variables del archivo
    source <(grep -E '^(IMAGEN_FINAL|FILENAME)=' "$INFO_FILE")
    
    if [ -z "$IMAGEN_FINAL" ] || [ ! -f "$IMAGEN_FINAL" ]; then
        echo -e "${RED}❌ No se encontró la imagen de disco.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Imagen encontrada: $IMAGEN_FINAL${NC}"
}

convertir_imagen() {
    local imagen="$1"
    local salida="/content/boot_disk.qcow2"
    
    echo -e "${YELLOW}🔄 Preparando imagen para QEMU...${NC}"
    
    # Si ya es qcow2, usar directamente
    if [[ "$imagen" == *.qcow2 ]]; then
        cp "$imagen" "$salida"
        echo -e "${GREEN}✅ Imagen qcow2 lista.${NC}"
        echo "$salida"
        return
    fi
    
    # Convertir a qcow2
    echo -e "${YELLOW}   Convirtiendo a qcow2 (puede tardar)...${NC}"
    qemu-img convert -p -f raw -O qcow2 "$imagen" "$salida" 2>/dev/null
    
    if [ -f "$salida" ] && [ $(stat -c%s "$salida") -gt 1000000 ]; then
        echo -e "${GREEN}✅ Conversión exitosa.${NC}"
        echo "$salida"
    else
        echo -e "${YELLOW}⚠️  Conversión fallida. Usando formato raw.${NC}"
        echo "$imagen"
    fi
}

iniciar_qemu() {
    local imagen="$1"
    
    # Limpiar
    pkill -9 qemu 2>/dev/null
    sudo fuser -k $((5900 + VNC_PORT))/tcp 2>/dev/null
    sudo fuser -k ${NOVNC_PORT}/tcp 2>/dev/null
    sleep 2
    
    echo -e "${YELLOW}🚀 Iniciando QEMU...${NC}"
    
    qemu-system-x86_64 \
        -m "$RAM_MB" \
        -smp 2 \
        -cpu max \
        -accel tcg,thread=multi \
        -machine type=pc \
        -vga std \
        -display vnc=:${VNC_PORT} \
        -drive file="$imagen",format=qcow2,index=0,media=disk \
        -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
    
    sleep 8
    
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        echo -e "${GREEN}✅ QEMU corriendo.${NC}"
    else
        # Reintentar con raw
        echo -e "${YELLOW}⚠️  Reintentando con formato alternativo...${NC}"
        pkill -9 qemu 2>/dev/null
        sleep 2
        
        qemu-system-x86_64 \
            -m "$RAM_MB" -smp 2 -cpu max \
            -accel tcg,thread=multi -machine type=pc \
            -vga std -display vnc=:${VNC_PORT} \
            -drive file="/content/boot_image_file",format=raw,index=0,media=disk \
            -usb -device usb-tablet -rtc base=localtime \
            -netdev user,id=net0 -device e1000,netdev=net0 \
            > /dev/null 2>&1 &
        
        sleep 8
        
        if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
            echo -e "${GREEN}✅ QEMU corriendo (modo raw).${NC}"
        else
            echo -e "${RED}❌ QEMU no pudo iniciar.${NC}"
            exit 1
        fi
    fi
}

iniciar_remoto() {
    echo -e "${YELLOW}🌐 Iniciando noVNC...${NC}"
    websockify --web /usr/share/novnc ${NOVNC_PORT} localhost:590${VNC_PORT} > /dev/null 2>&1 &
    sleep 2
    
    echo -e "${YELLOW}⛅ Creando túnel Cloudflare...${NC}"
    
    if ! command -v cloudflared &> /dev/null; then
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cf.deb
        sudo dpkg -i /tmp/cf.deb > /dev/null 2>&1
    fi
    
    cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${NOVNC_PORT} > /tmp/cf_log.txt 2>&1 &
    
    echo -e "${YELLOW}⏳ Esperando URL...${NC}"
    for i in {1..30}; do
        if grep -q "trycloudflare.com" /tmp/cf_log.txt 2>/dev/null; then
            local cf_url=$(grep -oP 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cf_log.txt | head -1)
            if [ -n "$cf_url" ]; then
                echo ""
                echo -e "${BLUE}============================================================${NC}"
                echo -e "${GREEN}🌍 ¡URL DE ACCESO!${NC}"
                echo -e "${GREEN}   $cf_url${NC}"
                echo -e "${BLUE}============================================================${NC}"
                echo ""
                return 0
            fi
        fi
        sleep 1.5
    done
    
    echo -e "${RED}⚠️  No se obtuvo URL.${NC}"
}

# ============================================================
# MAIN
# ============================================================

banner

instalar_todo
leer_info

DISK=$(convertir_imagen "$IMAGEN_FINAL")
iniciar_qemu "$DISK"
iniciar_remoto

echo -e "${GREEN}✅ LISTO. La VM está corriendo.${NC}"

while true; do
    sleep 60
done
