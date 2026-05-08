#!/bin/bash

# ============================================================
# ANALIZADOR 7z - Descarga, extrae y encuentra imagen booteable
# Uso: ./analyze_7z.sh "URL_DEL_ARCHIVO"
# Guarda resultado en /content/qemu_info.txt
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

URL="$1"
INFO_FILE="/content/qemu_info.txt"

banner() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}     🔍 ANALIZADOR DE ARCHIVOS 7z PARA QEMU${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

instalar_basicas() {
    echo -e "${YELLOW}🔧 Instalando herramientas básicas...${NC}"
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq wget p7zip-full python3 > /dev/null 2>&1
    echo -e "${GREEN}✅ Listo.${NC}"
}

obtener_enlace_directo() {
    local url="$1"
    
    if [[ "$url" == *"mediafire.com"* ]]; then
        echo -e "${YELLOW}🔍 Detectado Mediafire. Extrayendo enlace directo...${NC}"
        local html=$(wget -qO- --user-agent="Mozilla/5.0" "$url" 2>/dev/null)
        local direct_url=$(echo "$html" | grep -oP 'href="\Khttps://download\d+\.mediafire\.com/[^"]+' | head -1)
        
        if [ -n "$direct_url" ]; then
            direct_url=$(echo "$direct_url" | sed 's/&amp;/\&/g')
            echo -e "${GREEN}✅ Enlace directo obtenido.${NC}"
            echo "$direct_url"
        else
            echo -e "${YELLOW}⚠️  No se pudo extraer. Probando método alternativo...${NC}"
            # Método 2: buscar el ID del archivo
            local file_id=$(echo "$url" | grep -oP '/file/\K[^/]+')
            if [ -n "$file_id" ]; then
                echo "https://www.mediafire.com/file/${file_id}/"
            else
                echo "$url"
            fi
        fi
    else
        echo "$url"
    fi
}

obtener_filename() {
    local url="$1"
    local filename=""
    
    # Extraer el último segmento de la URL
    filename=$(echo "$url" | grep -oP '[^/]+(?=\?|$)' | tail -1)
    
    # Decodificar caracteres especiales
    filename=$(python3 -c "
import urllib.parse, sys
try:
    print(urllib.parse.unquote('$filename'))
except:
    print('$filename')
" 2>/dev/null || echo "$filename")
    
    # Si termina en /file o es genérico, usar nombre por defecto
    if [ -z "$filename" ] || [ "$filename" = "file" ] || [ "$filename" = "download" ]; then
        filename="windows_archive.7z"
    fi
    
    # Asegurar extensión .7z
    if [[ ! "$filename" =~ \.(7z|zip|rar)$ ]]; then
        filename="${filename}.7z"
    fi
    
    echo "$filename"
}

descargar() {
    local url="$1"
    local filename="$2"
    
    if [ -f "$filename" ]; then
        local size=$(stat -c%s "$filename" 2>/dev/null || echo "0")
        if [ "$size" -gt 1000000 ]; then
            echo -e "${GREEN}✅ Archivo ya descargado: $filename ($(echo "scale=2; $size/1048576" | bc) MB)${NC}"
            return 0
        else
            rm -f "$filename"
        fi
    fi
    
    echo -e "${YELLOW}📥 Descargando $filename...${NC}"
    wget -q --show-progress --user-agent="Mozilla/5.0" -O "$filename" "$url"
    
    if [ -f "$filename" ]; then
        local size=$(stat -c%s "$filename")
        local size_mb=$(echo "scale=2; $size/1048576" | bc)
        
        if [ "$size" -gt 1000000 ]; then
            echo -e "${GREEN}✅ Descargado: ${size_mb} MB${NC}"
        else
            echo -e "${RED}❌ Archivo muy pequeño (${size_mb} MB). Descarga fallida.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}❌ No se pudo descargar.${NC}"
        exit 1
    fi
}

extraer_todo() {
    local archivo="$1"
    local dir_salida="$2"
    
    mkdir -p "$dir_salida"
    
    echo -e "${YELLOW}📦 Extrayendo: $(basename "$archivo")...${NC}"
    
    if [[ "$archivo" == *.7z ]]; then
        7z x -y -o"$dir_salida" "$archivo" > /dev/null 2>&1
    elif [[ "$archivo" == *.zip ]]; then
        unzip -o -q "$archivo" -d "$dir_salida"
    else
        cp "$archivo" "$dir_salida/"
    fi
    
    # Buscar archivos 7z/zip anidados y extraerlos
    local anidados=$(find "$dir_salida" -maxdepth 1 -type f \( -name "*.7z" -o -name "*.zip" \) 2>/dev/null)
    
    if [ -n "$anidados" ]; then
        while IFS= read -r f; do
            local nombre=$(basename "$f" | sed 's/\.[^.]*$//')
            local subdir="$dir_salida/${nombre}_extracted"
            echo -e "${YELLOW}📦 Extrayendo nivel adicional: $(basename "$f")...${NC}"
            7z x -y -o"$subdir" "$f" > /dev/null 2>&1
            # Copiar contenido al directorio principal para simplificar búsqueda
            cp -r "$subdir"/* "$dir_salida/" 2>/dev/null
            rm -rf "$subdir"
        done <<< "$anidados"
    fi
    
    echo -e "${GREEN}✅ Extracción completada.${NC}"
}

buscar_imagen() {
    local dir="$1"
    local extensiones="vhd vhdx img qcow2 vmdk raw"
    
    echo -e "${YELLOW}🔍 Buscando imagen de disco booteable...${NC}"
    
    local mejor=""
    local mejor_size=0
    
    for ext in $extensiones; do
        while IFS= read -r f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            
            echo -e "   📄 $(basename "$f") (${size_mb} MB) [.$ext]"
            
            if [ "$size" -gt "$mejor_size" ] && [ "$size_mb" -gt 50 ]; then
                mejor="$f"
                mejor_size="$size"
            fi
        done < <(find "$dir" -type f -iname "*.$ext" 2>/dev/null)
    done
    
    # Si no encontró, buscar archivos grandes (>500MB)
    if [ -z "$mejor" ]; then
        echo -e "${YELLOW}   Buscando archivos grandes sin extensión...${NC}"
        while IFS= read -r f; do
            local size=$(stat -c%s "$f" 2>/dev/null || echo "0")
            local size_mb=$((size / 1048576))
            
            if [ "$size" -gt "$mejor_size" ] && [ "$size_mb" -gt 500 ]; then
                echo -e "   📄 $(basename "$f") (${size_mb} MB)"
                mejor="$f"
                mejor_size="$size"
            fi
        done < <(find "$dir" -type f 2>/dev/null)
    fi
    
    if [ -n "$mejor" ]; then
        local size_gb=$(echo "scale=2; $mejor_size/1073741824" | bc 2>/dev/null || echo "?")
        echo -e "${GREEN}✅ Imagen seleccionada: $(basename "$mejor") (${size_gb} GB)${NC}"
        echo "$mejor"
    else
        echo ""
    fi
}

# ============================================================
# MAIN
# ============================================================

banner

if [ -z "$URL" ]; then
    echo -e "${RED}❌ Debes proporcionar una URL.${NC}"
    echo -e "${YELLOW}   Uso: ./analyze_7z.sh \"URL\"${NC}"
    exit 1
fi

# Inicializar archivo de información
echo "# QEMU Image Info - $(date)" > "$INFO_FILE"
echo "URL=$URL" >> "$INFO_FILE"

# Instalar básicas
instalar_basicas

# Obtener enlace
DIRECT_URL=$(obtener_enlace_directo "$URL")
echo "DIRECT_URL=$DIRECT_URL" >> "$INFO_FILE"

# Obtener nombre
FILENAME=$(obtener_filename "$URL")
echo "FILENAME=$FILENAME" >> "$INFO_FILE"

# Descargar
descargar "$DIRECT_URL" "$FILENAME"

# Extraer
WORKDIR="/content/qemu_extracted"
rm -rf "$WORKDIR" 2>/dev/null
extraer_todo "$FILENAME" "$WORKDIR"

# Buscar imagen
IMAGEN=$(buscar_imagen "$WORKDIR")

if [ -z "$IMAGEN" ]; then
    echo -e "${RED}❌ No se encontró imagen de disco.${NC}"
    echo -e "${YELLOW}   Contenido del directorio:${NC}"
    find "$WORKDIR" -type f -exec ls -lh {} \; 2>/dev/null
    echo "IMAGEN=NOT_FOUND" >> "$INFO_FILE"
    exit 1
fi

# Guardar resultado
echo "IMAGEN=$IMAGEN" >> "$INFO_FILE"

# Copiar imagen a ubicación fija para el script 2
cp "$IMAGEN" /content/boot_image_file 2>/dev/null
echo "IMAGEN_FINAL=/content/boot_image_file" >> "$INFO_FILE"

echo -e "\n${GREEN}✅ ANÁLISIS COMPLETADO${NC}"
echo -e "${BLUE}   Archivo info: $INFO_FILE${NC}"
echo -e "${BLUE}   Imagen: $IMAGEN${NC}"
echo ""
echo -e "${YELLOW}   Ahora ejecuta el Script 2 para arrancar QEMU.${NC}"
