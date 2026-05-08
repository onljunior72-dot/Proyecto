#!/bin/bash

# ============================================================
# CONVERTIDOR VHD A QCOW2 + ARRANQUE QEMU
# Uso: ./convert_and_run.sh [RAM_MB]
# Convierte /content/boot_image_file (VHD) a QCOW2 y arranca
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RAM_MB="${1:-4096}"
VNC_PORT=7
NOVNC_PORT=6081
VHD_FILE="/content/boot_image_file"
QCOW2_FILE="/content/windows10.qcow2"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     🔄 CONVERTIDOR VHD + QEMU STARTER${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ============================================================
# Función: Instalar dependencias
# ============================================================
instalar_deps() {
    echo -e "${YELLOW}🔧 Instalando QEMU + herramientas...${NC}"
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

# ============================================================
# Función: Convertir VHD a QCOW2
# ============================================================
convertir_vhd() {
    if [ ! -f "$VHD_FILE" ]; then
        echo -e "${RED}❌ No se encontró $VHD_FILE${NC}"
        echo -e "${YELLOW}   Ejecuta primero analyze_7z.sh para descargar el VHD.${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}📦 Analizando archivo VHD...${NC}"
    VHD_SIZE=$(stat -c%s "$VHD_FILE" 2>/dev/null || echo "0")
    VHD_GB=$(echo "scale=2; $VHD_SIZE/1073741824" | bc 2>/dev/null || echo "?")
    echo -e "${BLUE}   Tamaño: ${VHD_GB} GB${NC}"
    
    # Verificar si ya existe el QCOW2
    if [ -f "$QCOW2_FILE" ]; then
        QCOW2_SIZE=$(stat -c%s "$QCOW2_FILE" 2>/dev/null || echo "0")
        if [ "$QCOW2_SIZE" -gt 1000000 ]; then
            echo -e "${GREEN}✅ QCOW2 ya existe y es válido.${NC}"
            echo -e "${BLUE}   Tamaño: $(echo "scale=2; $QCOW2_SIZE/1073741824" | bc) GB${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  QCOW2 existente es muy pequeño. Reconvertiendo...${NC}"
            rm -f "$QCOW2_FILE"
        fi
    fi
    
    echo -e "${YELLOW}🔄 Convirtiendo VHD a QCOW2...${NC}"
    echo -e "${BLUE}   Esto puede tardar 2-5 minutos...${NC}"
    
    # Convertir con barra de progreso
    qemu-img convert -p -f vpc -O qcow2 "$VHD_FILE" "$QCOW2_FILE" 2>&1
    
    if [ -f "$QCOW2_FILE" ] && [ $(stat -c%s "$QCOW2_FILE") -gt 1000000 ]; then
        QCOW2_GB=$(echo "scale=2; $(stat -c%s "$QCOW2_FILE")/1073741824" | bc)
        echo -e "${GREEN}✅ Conversión exitosa: ${QCOW2_GB} GB${NC}"
        
        # Mostrar ahorro de espacio
        if [ "$VHD_SIZE" -gt 0 ]; then
            AHORRO=$(echo "scale=1; 100 - ($(stat -c%s "$QCOW2_FILE") * 100 / $VHD_SIZE)" | bc 2>/dev/null || echo "?")
            echo -e "${GREEN}   Ahorro de espacio: ${AHORRO}%${NC}"
        fi
    else
        echo -e "${RED}❌ La conversión falló.${NC}"
        exit 1
    fi
}

# ============================================================
# Función: Iniciar QEMU con múltiples intentos
# ============================================================
iniciar_qemu() {
    local drive_file="$1"
    
    # Limpiar puertos
    pkill -9 qemu 2>/dev/null
    sudo fuser -k $((5900 + VNC_PORT))/tcp 2>/dev/null
    sudo fuser -k ${NOVNC_PORT}/tcp 2>/dev/null
    sleep 2
    
    echo -e "${YELLOW}🚀 Iniciando QEMU...${NC}"
    
    # Intento 1: IDE + cpu genérica
    echo -e "${BLUE}   Intento 1: IDE + qemu64...${NC}"
    qemu-system-x86_64 \
        -m "$RAM_MB" -smp 1 -cpu qemu64 \
        -machine type=pc -vga std \
        -display vnc=:${VNC_PORT} \
        -drive file="$drive_file",format=qcow2,if=ide,index=0 \
        -boot c -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
    
    sleep 8
    
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        echo -e "${GREEN}✅ QEMU corriendo (IDE + qemu64)${NC}"
        return 0
    fi
    
    # Intento 2: IDE + cpu max
    echo -e "${YELLOW}   Intento 2: IDE + cpu max...${NC}"
    pkill -9 qemu 2>/dev/null
    sleep 2
    
    qemu-system-x86_64 \
        -m "$RAM_MB" -smp 2 -cpu max \
        -accel tcg,thread=multi -machine type=pc \
        -vga std -display vnc=:${VNC_PORT} \
        -drive file="$drive_file",format=qcow2,if=ide,index=0 \
        -boot c -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
    
    sleep 8
    
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        echo -e "${GREEN}✅ QEMU corriendo (IDE + max)${NC}"
        return 0
    fi
    
    # Intento 3: SATA + ahci
    echo -e "${YELLOW}   Intento 3: SATA + AHCI...${NC}"
    pkill -9 qemu 2>/dev/null
    sleep 2
    
    qemu-system-x86_64 \
        -m "$RAM_MB" -smp 2 -cpu max \
        -accel tcg,thread=multi -machine type=q35 \
        -vga std -display vnc=:${VNC_PORT} \
        -device ahci,id=ahci \
        -drive file="$drive_file",format=qcow2,if=none,id=disk \
        -device ide-hd,drive=disk,bus=ahci.0 \
        -boot c -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
    
    sleep 8
    
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        echo -e "${GREEN}✅ QEMU corriendo (SATA + AHCI)${NC}"
        return 0
    fi
    
    echo -e "${RED}❌ Ningún intento funcionó.${NC}"
    return 1
}

# ============================================================
# Función: Iniciar noVNC + Cloudflare
# ============================================================
iniciar_remoto() {
    echo -e "${YELLOW}🌐 Iniciando noVNC...${NC}"
    pkill websockify 2>/dev/null
    websockify --web /usr/share/novnc ${NOVNC_PORT} localhost:590${VNC_PORT} > /dev/null 2>&1 &
    sleep 2
    
    echo -e "${YELLOW}⛅ Creando túnel Cloudflare...${NC}"
    pkill cloudflared 2>/dev/null
    
    if ! command -v cloudflared &> /dev/null; then
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cf.deb
        sudo dpkg -i /tmp/cf.deb > /dev/null 2>&1
    fi
    
    cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${NOVNC_PORT} > /tmp/cf.log 2>&1 &
    
    echo -e "${YELLOW}⏳ Esperando URL (20 segundos)...${NC}"
    for i in {1..20}; do
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
        sleep 1.5
    done
    
    echo -e "${YELLOW}⚠️  URL no encontrada aún. Revisa con: cat /tmp/cf.log${NC}"
}

# ============================================================
# MAIN
# ============================================================

# Paso 1: Instalar
instalar_deps

# Paso 2: Convertir VHD
convertir_vhd

# Paso 3: Iniciar QEMU
iniciar_qemu "$QCOW2_FILE"

# Paso 4: Acceso remoto
iniciar_remoto

echo -e "${GREEN}✅ Proceso completado.${NC}"
echo -e "${YELLOW}   Si Windows falla con BSOD, reinstala drivers en Modo Seguro.${NC}"

# Mantener vivo
while true; do
    sleep 60
done
