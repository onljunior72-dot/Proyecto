#!/bin/bash

# ============================================================
# ANALIZADOR 7z - Descarga, extrae y encuentra imagen booteable
# Uso: ./analyze_7z.sh "URL"
# Probado con Mediafire
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

URL="$1"
INFO_FILE="/content/qemu_info.txt"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}     🔍 ANALIZADOR 7z PARA QEMU${NC}"
echo -e "${BLUE}============================================================${NC}"

# Instalar
echo -e "${YELLOW}🔧 Instalando...${NC}"
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq wget p7zip-full > /dev/null 2>&1
echo -e "${GREEN}✅ Listo.${NC}"

# Inicializar archivo de info
echo "# $(date)" > "$INFO_FILE"
echo "URL=$URL" >> "$INFO_FILE"

# Obtener enlace directo
DIRECT_URL="$URL"

if [[ "$URL" == *"mediafire.com"* ]]; then
    echo -e "${YELLOW}🔍 Extrayendo enlace directo de Mediafire...${NC}"
    
    # MÉTODO PROBADO: descargar HTML y buscar con grep
    HTML=$(wget -qO- --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$URL" 2>/dev/null)
    
    # Buscar patrón de descarga
    EXTRACTED=$(echo "$HTML" | grep -oP 'https?://download\d+\.mediafire\.com/[^"'\'' ]+' | head -1)
    
    if [ -n "$EXTRACTED" ]; then
        DIRECT_URL="$EXTRACTED"
        echo -e "${GREEN}✅ Enlace obtenido${NC}"
    else
        echo -e "${RED}❌ No se pudo extraer el enlace.${NC}"
        echo "ERROR=NO_LINK" >> "$INFO_FILE"
        exit 1
    fi
fi

echo "DIRECT_URL=$DIRECT_URL" >> "$INFO_FILE"

# Nombre de archivo fijo para simplificar
FILENAME="windows_download.7z"
echo "FILENAME=$FILENAME" >> "$INFO_FILE"

# Descargar
echo -e "${YELLOW}📥 Descargando...${NC}"
wget -q --show-progress --user-agent="Mozilla/5.0" -O "$FILENAME" "$DIRECT_URL"

# Verificar descarga
if [ ! -f "$FILENAME" ]; then
    echo -e "${RED}❌ No se descargó nada.${NC}"
    echo "ERROR=DOWNLOAD_FAILED" >> "$INFO_FILE"
    exit 1
fi

SIZE=$(stat -c%s "$FILENAME" 2>/dev/null || echo "0")
SIZE_MB=$(echo "scale=2; $SIZE/1048576" | bc)

if [ "$SIZE" -lt 500000 ]; then
    echo -e "${RED}❌ Archivo muy pequeño (${SIZE_MB} MB)${NC}"
    echo "ERROR=FILE_TOO_SMALL" >> "$INFO_FILE"
    exit 1
fi

echo -e "${GREEN}✅ Descargado: ${SIZE_MB} MB${NC}"
echo "SIZE_MB=$SIZE_MB" >> "$INFO_FILE"

# Extraer
WORKDIR="/content/qemu_extracted"
rm -rf "$WORKDIR" 2>/dev/null
mkdir -p "$WORKDIR"

echo -e "${YELLOW}📦 Extrayendo...${NC}"
7z x -y -o"$WORKDIR" "$FILENAME" > /dev/null 2>&1
echo -e "${GREEN}✅ Extracción completada.${NC}"

# Buscar archivos 7z anidados y extraerlos también
ANIDADOS=$(find "$WORKDIR" -maxdepth 1 -name "*.7z" -type f 2>/dev/null)
if [ -n "$ANIDADOS" ]; then
    echo -e "${YELLOW}📦 Extrayendo archivos anidados...${NC}"
    while IFS= read -r f; do
        echo -e "   Extrayendo: $(basename "$f")"
        7z x -y -o"$WORKDIR" "$f" > /dev/null 2>&1
    done <<< "$ANIDADOS"
fi

# Buscar imagen booteable
echo -e "${YELLOW}🔍 Buscando imagen...${NC}"
BEST=""
BEST_SIZE=0

for ext in vhd vhdx img qcow2 vmdk raw; do
    while IFS= read -r f; do
        SIZE=$(stat -c%s "$f" 2>/dev/null || echo "0")
        SIZE_MB=$((SIZE / 1048576))
        
        echo -e "   📄 $(basename "$f") (${SIZE_MB} MB)"
        
        if [ "$SIZE" -gt "$BEST_SIZE" ] && [ "$SIZE_MB" -gt 50 ]; then
            BEST="$f"
            BEST_SIZE="$SIZE"
        fi
    done < <(find "$WORKDIR" -type f -iname "*.$ext" 2>/dev/null)
done

# Si no encontró, buscar archivos grandes (>500MB)
if [ -z "$BEST" ]; then
    echo -e "${YELLOW}   Buscando archivos grandes...${NC}"
    while IFS= read -r f; do
        SIZE=$(stat -c%s "$f" 2>/dev/null || echo "0")
        SIZE_MB=$((SIZE / 1048576))
        if [ "$SIZE" -gt "$BEST_SIZE" ] && [ "$SIZE_MB" -gt 500 ]; then
            echo -e "   📄 $(basename "$f") (${SIZE_MB} MB)"
            BEST="$f"
            BEST_SIZE="$SIZE"
        fi
    done < <(find "$WORKDIR" -type f 2>/dev/null)
fi

if [ -n "$BEST" ]; then
    cp "$BEST" /content/boot_image_file
    echo "IMAGEN_FINAL=/content/boot_image_file" >> "$INFO_FILE"
    GB=$(echo "scale=2; $BEST_SIZE/1073741824" | bc 2>/dev/null || echo "?")
    echo -e "${GREEN}✅ Imagen: $(basename "$BEST") (${GB} GB)${NC}"
    echo -e "${GREEN}✅ Copiada a /content/boot_image_file${NC}"
else
    echo -e "${RED}❌ No se encontró imagen.${NC}"
    echo "ERROR=NO_IMAGE" >> "$INFO_FILE"
    
    echo -e "${YELLOW}   Contenido del directorio:${NC}"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null | head -20
    
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ ANÁLISIS COMPLETADO${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}Ahora ejecuta el Script 2 para arrancar.${NC}"
