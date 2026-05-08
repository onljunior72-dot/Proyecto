#!/bin/bash

# ============================================================
# QEMU Windows Installer para Google Colab
# Uso: ./qemu_windows.sh "URL_DEL_ARCHIVO_7Z" [RAM_MB]
# Ejemplo: ./qemu_windows.sh "https://www.mediafire.com/file/xxx/WINDOWS10X64.7z/file" 4096
# ============================================================

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuración
URL="$1"
RAM_MB="${2:-4096}"
VNC_PORT=7
NOVNC_PORT=6081

# ============================================================
# Función: Mostrar banner
# ============================================================
banner() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}     🖥️  QEMU WINDOWS INSTALLER - GOOGLE COLAB${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

# ============================================================
# Función: Instalar dependencias
# ============================================================
instalar_deps() {
    echo -e "${YELLOW}🔧 Instalando dependencias...${NC}"
    sudo rm -f /etc/apt/sources.list.d/*.list 2>/dev/null
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq --fix-missing \
        qemu-system-x86 qemu-utils novnc websockify wget p7zip-full \
        python3-pip > /dev/null 2>&1
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        echo -e "${RED}❌ QEMU no se instaló correctamente.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Dependencias instaladas.${NC}"
}

# ============================================================
# Función: Obtener enlace directo (Mediafire o normal)
# ============================================================
obtener_enlace() {
    local url="$1"
    
    if [[ "$url" == *"mediafire.com"* ]]; then
        echo -e "${YELLOW}🔍 Detectado Mediafire. Extrayendo enlace directo...${NC}"
        
        # Descargar página y extraer enlace
        local html=$(wget -qO- --user-agent="Mozilla/5.0" "$url" 2>/dev/null)
        local direct_url=$(echo "$html" | grep -oP 'href="\Khttps://download\d+\.mediafire\.com/[^"]+' | head -1)
        
        if [ -n "$direct_url" ]; then
            direct_url=$(echo "$direct_url" | sed 's/&amp;/\&/g')
            echo -e "${GREEN}✅ Enlace directo obtenido.${NC}"
            echo "$direct_url"
        else
            echo -e "${YELLOW}⚠️  No se pudo extraer enlace directo. Usando URL original.${NC}"
            echo "$url"
        fi
    else
        echo "$url"
    fi
}

# ============================================================
# Función: Descargar archivo
# ============================================================
descargar() {
    local url="$1"
    local filename="$2"
    
    if [ -f "$filename" ]; then
        local size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        if [ "$size" -gt 500000 ]; then
            echo -e "${GREEN}✅ Archivo '$filename' ya existe.${NC}"
            return 0
        fi
    fi
    
    echo -e "${YELLOW}📥 Descargando $filename...${NC}"
    wget -q --show-progress --user-agent="Mozilla/5.0" -O "$filename" "$url"
    
    if [ -f "$filename" ]; then
        local size_mb=$(stat -c%s "$filename" | awk '{printf "%.2f", $1/1048576}')
        echo -e "${GREEN}✅ Descargado: ${size_mb} MB${NC}"
    else
        echo -e "${RED}❌ Error en la descarga.${NC}"
        exit 1
    fi
}

# ============================================================
# Función: Extraer recursivamente (soporta 7z anidados)
# ============================================================
extraer_recursivo() {
    local archivo="$1"
    local dir_salida="$2"
    local nivel="${3:-1}"
    
    mkdir -p "$dir_salida"
    
    if [[ "$archivo" == *.7z ]]; then
        echo -e "${YELLOW}📦 Extrayendo nivel $nivel: $(basename "$archivo")...${NC}"
        7z x -y -o"$dir_salida" "$archivo" > /dev/null 2>&1
        
        # Buscar más archivos 7z anidados
        local anidados=$(find "$dir_salida" -name "*.7z" -type f 2>/dev/null)
        if [ -n "$anidados" ]; then
            while IFS= read -r f; do
                local subdir="${f}_extraido"
                extraer_recursivo "$f" "$subdir" $((nivel + 1))
            done <<< "$anidados"
        fi
    elif [[ "$archivo" == *.zip ]]; then
        echo -e "${YELLOW}📦 Extrayendo ZIP: $(basename "$archivo")...${NC}"
        unzip -o -q "$archivo" -d "$dir_salida"
    else
        cp "$archivo" "$dir_salida/" 2>/dev/null
    fi
}

# ============================================================
# Función: Buscar imagen de disco booteable
# ============================================================
buscar_imagen() {
    local dir="$1"
    local extensiones=("vhd" "vhdx" "img" "qcow2" "vmdk" "raw")
    
    echo -e "${YELLOW}🔍 Buscando imagen de disco booteable...${NC}"
    
    local mejor=""
    local mejor_size=0
    
    # Buscar por extensión primero
    for ext in "${extensiones[@]}"; do
        while IFS= read -r f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            
            if [ "$size" -gt "$mejor_size" ] && [ "$size_mb" -gt 100 ]; then
                mejor="$f"
                mejor_size="$size"
            fi
        done < <(find "$dir" -type f -iname "*.$ext" 2>/dev/null)
    done
    
    # Si no encontró por extensión, buscar archivos grandes
    if [ -z "$mejor" ]; then
        while IFS= read -r f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            
            if [ "$size" -gt "$mejor_size" ] && [ "$size_mb" -gt 500 ]; then
                mejor="$f"
                mejor_size="$size"
            fi
        done < <(find "$dir" -type f 2>/dev/null)
    fi
    
    if [ -n "$mejor" ]; then
        local size_gb=$(echo "scale=2; $mejor_size/1073741824" | bc 2>/dev/null || echo "?")
        echo -e "${GREEN}✅ Imagen encontrada: $mejor (${size_gb} GB)${NC}"
        echo "$mejor"
    else
        echo ""
    fi
}

# ============================================================
# Función: Iniciar QEMU
# ============================================================
iniciar_qemu() {
    local imagen="$1"
    
    # Convertir a qcow2 si no lo es
    local drive_final="$imagen"
    if [[ ! "$imagen" == *.qcow2 ]]; then
        echo -e "${YELLOW}🔄 Convirtiendo a formato qcow2...${NC}"
        qemu-img convert -f raw -O qcow2 "$imagen" /content/win_boot.qcow2 2>/dev/null
        drive_final="/content/win_boot.qcow2"
        echo -e "${GREEN}✅ Conversión completada.${NC}"
    fi
    
    # Limpiar puertos
    pkill -9 qemu 2>/dev/null
    sudo fuser -k $((5900 + VNC_PORT))/tcp 2>/dev/null
    sudo fuser -k ${NOVNC_PORT}/tcp 2>/dev/null
    sleep 2
    
    echo -e "${YELLOW}🚀 Iniciando QEMU con ${RAM_MB}MB RAM...${NC}"
    
    qemu-system-x86_64 \
        -m "$RAM_MB" \
        -smp 2 \
        -cpu max \
        -accel tcg,thread=multi \
        -machine type=pc \
        -vga std \
        -display vnc=:${VNC_PORT} \
        -drive file="$drive_final",format=qcow2,index=0,media=disk \
        -usb -device usb-tablet \
        -rtc base=localtime \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        > /dev/null 2>&1 &
    
    sleep 5
    
    # Verificar que QEMU está corriendo
    if ss -tlnp 2>/dev/null | grep -q "590${VNC_PORT}"; then
        echo -e "${GREEN}✅ QEMU corriendo en puerto 590${VNC_PORT}${NC}"
    else
        echo -e "${RED}❌ QEMU no inició correctamente.${NC}"
        exit 1
    fi
}

# ============================================================
# Función: Iniciar noVNC + Cloudflare
# ============================================================
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
    
    # Esperar URL
    echo -e "${YELLOW}⏳ Esperando URL pública...${NC}"
    for i in {1..30}; do
        if grep -q "trycloudflare.com" /tmp/cf_log.txt 2>/dev/null; then
            local cf_url=$(grep -oP 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' /tmp/cf_log.txt | head -1)
            if [ -n "$cf_url" ]; then
                echo ""
                echo -e "${BLUE}============================================================${NC}"
                echo -e "${GREEN}🌍 URL DE ACCESO:${NC}"
                echo -e "${GREEN}   $cf_url${NC}"
                echo -e "${BLUE}============================================================${NC}"
                echo -e "${YELLOW}💡 Si pide contraseña VNC, usa: colab123${NC}"
                echo ""
                return 0
            fi
        fi
        sleep 1.5
    done
    
    echo -e "${RED}⚠️  No se pudo obtener URL de Cloudflare.${NC}"
}

# ============================================================
# MAIN
# ============================================================

banner

# Validar URL
if [ -z "$URL" ]; then
    echo -e "${RED}❌ Debes proporcionar una URL.${NC}"
    echo -e "${YELLOW}   Uso: ./qemu_windows.sh \"URL_DEL_ARCHIVO\" [RAM_MB]${NC}"
    exit 1
fi

# Paso 1: Instalar
instalar_deps

# Paso 2: Obtener enlace directo
DIRECT_URL=$(obtener_enlace "$URL")

# Paso 3: Descargar
FILENAME=$(basename "$(echo "$URL" | sed 's/\?.*//')")
if [ -z "$FILENAME" ]; then
    FILENAME="windows.7z"
fi
descargar "$DIRECT_URL" "$FILENAME"

# Paso 4: Extraer
WORKDIR="/content/qemu_extracted"
rm -rf "$WORKDIR" 2>/dev/null
mkdir -p "$WORKDIR"
extraer_recursivo "$FILENAME" "$WORKDIR"

# Paso 5: Buscar imagen
IMAGEN=$(buscar_imagen "$WORKDIR")

if [ -z "$IMAGEN" ]; then
    echo -e "${RED}❌ No se encontró ninguna imagen de disco.${NC}"
    echo -e "${YELLOW}   Contenido extraído:${NC}"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    exit 1
fi

# Paso 6: Iniciar QEMU
iniciar_qemu "$IMAGEN"

# Paso 7: Iniciar acceso remoto
iniciar_remoto

# Mantener vivo
echo -e "${GREEN}✅ Todo listo. La VM está corriendo.${NC}"
echo -e "${YELLOW}   Presiona Ctrl+C para detener.${NC}"

# Loop infinito para mantener la sesión
while true; do
    sleep 60
done
