#!/usr/bin/env bash

# Supported Firmwares:
# Aonly OTA
# Raw image
# tarmd5
# chunk image
# QFIL
# AB OTA
# Image zip
# ozip
# Sony ftf
# ZTE update.zip
# KDDI .bin
# bin images
# pac
# sign images
# sign auth DA images
# nb0
# kdz
# RUU
# Amlogic upgrade package
# Rockchip upgrade package

superimage() {
    if [ -f super.img ]; then
        echo "Creating super.img.raw ..."
        $simg2img super.img super.img.raw 2>/dev/null
    fi
    if [[ ! -s super.img.raw ]] && [ -f super.img ]; then
        mv super.img super.img.raw
    fi
    for partition in $PARTITIONS; do
        ($lpunpack --partition="$partition"_a super.img.raw || $lpunpack --partition="$partition" super.img.raw) 2>/dev/null
        if [ -f "$partition"_a.img ]; then
            mv "$partition"_a.img "$partition".img
        elif [ -f "$romzip" ]; then
            foundpartitions=$(7z l -ba "${romzip}" | rev | gawk '{ print $1 }' | rev | grep "$partition".img)
            7z e -y "${romzip}" "$foundpartitions" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
        fi
    done
    rm -rf super.img*
}

usage() {
    echo "Usage: $0 <Path to firmware> [Output Dir]"
    echo -e "\tPath to firmware: the zip!"
    echo -e "\tOutput Dir: the output dir!"
}

if [ "$1" == "" ]; then
    echo "BRUH: Enter all needed parameters"
    usage
    exit 1
fi

LOCALDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
toolsdir="$LOCALDIR/tools"

EXTERNAL_TOOLS=(
    https://github.com/bkerler/oppo_ozip_decrypt
)

# Start cloning requires repositories (tools)
for tool_url in "${EXTERNAL_TOOLS[@]}"; do
    tool_path="${toolsdir}/${tool_url##*/}"
    if ! [[ -d ${tool_path} ]]; then
        git clone -q "${tool_url}" "${tool_path}" >> /dev/null 2>&1
    else
        git -C "${tool_path}" pull >> /dev/null 2>&1  
    fi
done

simg2img="$toolsdir/simg2img"
packsparseimg="$toolsdir/packsparseimg"
unsin="$toolsdir/unsin"
otadump="$toolsdir/otadump"
sdat2img="$toolsdir/sdat2img.py"
ozipdecrypt="$toolsdir/oppo_ozip_decrypt/ozipdecrypt.py"
lpunpack="$toolsdir/lpunpack"
splituapp="$toolsdir/splituapp"
pacextractor="$toolsdir/pacExtractor.py"
nb0_extract="$toolsdir/nb0-extract"
kdz_extract="$toolsdir/unkdz.py"
dz_extract="$toolsdir/undz.py"
ruu="$toolsdir/RUU_Decrypt_Tool"
aml_extract="$toolsdir/aml-upgrade-package-extract"
star="$toolsdir/star"
afptool_extract="$toolsdir/afptool"
rk_extract="$toolsdir/rkImageMaker"

romzip="$(realpath "$1")"
romzipext="${romzip}##*.}"
filename="$(basename "${romzip}%%.*}")"
PARTITIONS="super system vendor cust odm oem factory product xrom modem dtbo dtb boot recovery tz systemex oppo_product preload_common system_ext system_other opproduct reserve india my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap my_custom my_manifest my_carrier my_region my_bigball my_version special_preload vendor_dlkm odm_dlkm system_dlkm init_boot vendor_kernel_boot vendor_boot mi_ext boot-debug vendor_boot-debug hw_product product_h preas preavs tvconfig tvservice linux_rootfs_a factory_a 3rd_a 3rd_rw boot_gki boot_xts my_reserve boot_oplus"
EXT4PARTITIONS="system vendor cust odm oem factory product xrom systemex oppo_product preload_common hw_product product_h preas preavs"
OTHERPARTITIONS="tz.mbn:tz tz.img:tz modem.img:modem NON-HLOS:modem boot-verified.img:boot dtbo-verified.img:dtbo"

echo "Create Temp and out dir"
outdir="$LOCALDIR/out"
if [ ! "$2" == "" ]; then
    outdir="$(realpath "$2")"
fi
tmpdir="${outdir}/tmp"
mkdir -p "${tmpdir}"
mkdir -p "${outdir}"
cd "${tmpdir}" || exit

MAGIC=$(head -c12 "${romzip}" | tr -d '\0')

# File is '.ozip'
if [[ "${MAGIC}" == "OPPOENCRYPT!" ]] || [[ "${romzipext}" == "ozip" ]]; then

    # Function to archive directories to a fake image.
    directory_archive() {
        # We probably have 'vendor/' extracted to a directory.
        7z x "${tmpdir}/$(basename "${romzip%%.*}").zip" -o"${tmpdir}/ozip/"  > /dev/null

        # Set a variable for working directory
        WORKING_OZIP=${tmpdir}/ozip

        # Convert all directories to 'images' (even though it's an archive)
        for image in recovery system vendor; do
            # Archive to a '.zip', first
            7z a -r "${outdir}"/${image}.zip "${WORKING_OZIP}"/${image}/* > /dev/null

            # Move '.zip' to .'img' to get recognized by dumper
            mv "${outdir}"/${image}.zip "${outdir}"/${image}.img

            # Remove remaining directory
            rm -rf "${outdir}"/${image}/
        done

        # Move every image from 'ozip/' to '${outdir}'
        find "${tmpdir}/ozip/." -name "*.img" -exec mv {} "${outdir}" \; 

        # Delete extracted directory
        rm -rf "${tmpdir}/ozip"
    }

    # Copy over encrypted archive to our directory
    cp "${romzip}" "${tmpdir}"

    # Start decrypting the archive
    echo "[INFO] Decrypting '.ozip' through 'oppo_ozip_decrypt'..."
    python3 "$ozipdecrypt" "${tmpdir}/${filename}.ozip" > /dev/null
    rm -rf "${tmpdir}/${filename}.ozip" "${tmpdir}"/out "${tmpdir}"/tmp

    # Run extractor over decrypted archive
    if $(7z l "${tmpdir}/${filename}.zip" | grep -q system.img); then
        "$LOCALDIR/extractor.sh" "${tmpdir}/${filename}.zip" "${outdir}"
    else
        directory_archive
    fi
    rm -rf "${tmpdir}/${filename}.zip" > /dev/null
    exit
fi

if [[ $(echo "${romzip}" | grep kdz) ]]; then
    echo "KDZ detected"
    python3 "$kdz_extract" -f "${romzip}" -x -o "./"
    dzfile=$(ls *.dz)
    python3 "$dz_extract" -f "$dzfile" -s -o "./"
    # Some known dz-partitions "gpt_main persist misc metadata vendor system system_other product userdata gpt_backup tz boot dtbo vbmeta cust oem odm factory modem NON-HLOS"
    find . -maxdepth 4 -type f -name "*.image" | rename 's/.image/.img/g' > /dev/null 2>&1
    find . -maxdepth 4 -type f -name "*_a.img" | rename 's/_a.img/.img/g' > /dev/null 2>&1
    if [[ -f super.img ]]; then
        superimage
    fi
    for partition in $PARTITIONS; do
        [[ -e "$tmpdir/$partition.img" ]] && mv "$tmpdir/$partition.img" "${outdir}/$partition.img"
    done
    rm -rf "$tmpdir"
    exit 0
fi

if [[ $(echo "${romzip}" | grep -i ruu_ | grep -i exe) ]]; then
    echo "RUU detected"
    cp "${romzip}" "$tmpdir"
    romzip="$tmpdir/$(basename "${romzip}")"
    $ruu -s "${romzip}" 2>/dev/null
    $ruu -f "${romzip}" 2>/dev/null
    find "$tmpdir/OUT"* -name *.img -exec mv {} "$tmpdir" \;
    for partition in $PARTITIONS; do
        [[ -e "$tmpdir/$partition.img" ]] && mv "$tmpdir/$partition.img" "${outdir}/$partition.img"
    done
    rm -rf "$tmpdir"
    exit 0
fi

if grep -q "rockchip" "${romzip}"; then
    echo "[INFO] Detected rockchip archive"

    # Start the extraction of partition
    ## Logical
    echo "[INFO] Extracting partitions with 'rkImageMaker'..."
    "${rk_extract}" -unpack "${romzip}" "${tmpdir}" > /dev/null || {
        echo "[ERROR] Extraction with 'rkImageMaker' failed."
        exit 1
    }

    ## Firmware
    echo "[INFO] Extracting partitions with 'afptool'..."
    "${afptool_extract}" -unpack "${tmpdir}/firmware.img" "${tmpdir}" > /dev/null || {
        echo "[ERROR] Extraction with 'afptool' failed." 
        exit 1
    }

    # In case output was a 'super.img', execute 'superimage'
    if [ -f "${tmpdir}/Image/super.img" ]; then
        unset romzip
        mv "${tmpdir}/Image/super.img" "${tmpdir}/super.img"
        superimage
    fi

    # Move everything to the '${outdir}' directory
    for p in $PARTITIONS; do
        [ -e "${tmpdir}/Image/${p}.img" ] && \
            mv "${tmpdir}/Image/${p}.img" "${outdir}/${p}.img"
        [ -e "${tmpdir}/${p}.img" ] && \
            mv "${tmpdir}/${p}.img" "${outdir}/${p}.img"
    done

    # Clean-up and exit
    rm -rf "${tmpdir}"
    exit 0
fi

if [[ $(7z l -ba "${romzip}" | grep -i aml) ]]; then
    echo "aml detected"
    cp "${romzip}" "$tmpdir"
    romzip="$tmpdir/$(basename "${romzip}")"
    7z e -y "${romzip}" >> "$tmpdir"/zip.log
    $aml_extract $(find . -type f -name "*aml*.img")
    rename 's/.PARTITION$/.img/' *.PARTITION
    rename 's/_aml_dtb.img$/dtb.img/' *.img
    rename 's/_a.img/.img/' *.img
    if [[ -f super.img ]]; then
        superimage
    fi
    for partition in $PARTITIONS; do
        [[ -e "$tmpdir/$partition.img" ]] && mv "$tmpdir/$partition.img" "${outdir}/$partition.img"
    done
    rm -rf "$tmpdir"
    exit 0
fi

if [[ ! $(7z l -ba "${romzip}" | grep ".*system.ext4.tar.*\|.*.tar\|.*chunk\|system\/build.prop\|system.new.dat\|system_new.img\|system.img\|system-sign.img\|system.bin\|payload.bin\|.*.zip\|.*.rar\|.*rawprogram*\|system.sin\|.*system_.*\.sin\|system-p\|super\|UPDATE.APP\|.*.pac\|.*.nb0" | grep -v ".*chunk.*\.so$") ]]; then
    echo "BRUH: This type of firmwares not supported"
    cd "$LOCALDIR" || exit
    rm -rf "$tmpdir" "${outdir}"
    exit 1
fi

echo "Extracting firmware on: ${outdir}"

# Extract firmware partitions
for partition in ${OTHERPARTITIONS}; do
    # Set the names for the partition(s)
    IN=$(echo "$partition" | cut -f 1 -d ":")
    OUT=$(echo "$partition" | cut -f 2 -d ":")

    # Check if partition is present on archive
    if $(7z l -ba "${romzip}" | grep -q "$IN"); then
        echo "[INFO] Extracting ${IN}..."

        # Extract to '${outdir}'
        7zz x "${romzip}" "${IN}" -so > "${outdir}"/"${IN}".sparse

        # Convert from sparse to RAW image
        $simg2img "${outdir}/${IN}".sparse "${outdir}/${OUT}".img
        rm -rf "${outdir}/${IN}".sparse
    fi
done

if [[ $(7z l -ba "${romzip}" | grep firmware-update/dtbo.img) ]]; then
    7z e -y "${romzip}" firmware-update/dtbo.img 2>/dev/null >> "$tmpdir"/zip.log
fi
if [[ $(7z l -ba "${romzip}" | grep system.new.dat) ]]; then
    echo "Aonly OTA detected"
    for partition in $PARTITIONS; do
        7z e -y "${romzip}" "$partition".new.dat* "$partition".transfer.list "$partition".img 2>/dev/null >> "$tmpdir"/zip.log
        7z e -y "${romzip}" "$partition".*.new.dat* "$partition".*.transfer.list "$partition".*.img 2>/dev/null >> "$tmpdir"/zip.log
        rename 's/(\w+)\.(\d+)\.(\w+)/$1.$3/' *
        # For Oplus A-only OTAs, eg OnePlus Nord 2. Regex matches the 8 digits of Oplus NV ID (prop ro.build.oplus_nv_id) to remove them.
        # hello@world:~/test_regex# rename -n 's/(\w+)\.(\d+)\.(\w+)/$1.$3/' *
        # rename(my_bigball.00011011.new.dat.br, my_bigball.new.dat.br)
        # rename(my_bigball.00011011.patch.dat, my_bigball.patch.dat)
        # rename(my_bigball.00011011.transfer.list, my_bigball.transfer.list)
        if [[ -f $partition.new.dat.1 ]]; then
            cat "$partition".new.dat.{0..999} 2>/dev/null >> "$partition".new.dat
            rm -rf "$partition".new.dat.{0..999}
        fi
        ls | grep "\.new\.dat" | while read i; do
            line=$(echo "$i" | cut -d"." -f1)
            if [[ $(echo "$i" | grep "\.dat\.xz") ]]; then
                7z e -y "$i" 2>/dev/null >> "$tmpdir"/zip.log
                rm -rf "$i"
            fi
            if [[ $(echo "$i" | grep "\.dat\.br") ]]; then
                echo "Converting brotli $partition dat to normal"
                brotli -d "$i"
                rm -f "$i"
            fi
            echo "Extracting $partition"
            python3 "$sdat2img" "$line".transfer.list "$line".new.dat "${outdir}"/"$line".img > "$tmpdir"/extract.log
            rm -rf "$line".transfer.list "$line".new.dat
        done
    done
elif [[ $(7z l -ba "${romzip}" | grep rawprogram) ]]; then
    echo "QFIL detected"
    rawprograms=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep rawprogram)
    7z e -y "${romzip}" "$rawprograms" 2>/dev/null >> "$tmpdir"/zip.log
    for partition in $PARTITIONS; do
        partitionsonzip=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "$partition")
        if [[ ! $partitionsonzip == "" ]]; then
            7z e -y "${romzip}" "$partitionsonzip" 2>/dev/null >> "$tmpdir"/zip.log
            if [[ ! -f "$partition.img" ]]; then
                if [[ -f "$partition.raw.img" ]]; then
                    mv "$partition.raw.img" "$partition.img"
                else
                    rawprogramsfile=$(grep -rlw "$partition" rawprogram*.xml)
                    $packsparseimg -t "$partition" -x "$rawprogramsfile" > "$tmpdir"/extract.log
                    mv "$partition.raw" "$partition.img"
                fi
            fi
        fi
    done
    if [[ -f super.img ]]; then
        superimage
    fi
elif [[ $(7z l -ba "${romzip}" | grep nb0) ]]; then
    echo "nb0 detected"
    to_extract=$(7z l "${romzip}" | grep ".*.nb0" | gawk '{ print $6 }')
    echo "$to_extract"
    7z e -y "${romzip}" "$to_extract" 2>/dev/null >> "$tmpdir"/zip.log
    $nb0_extract "$to_extract" "$tmpdir"
    for partition in $PARTITIONS; do
        part=$(ls -l | grep ".*$partition.img" | gawk '{ print $9 }')
        mv "$part" "$partition".img
    done
    romzip=""
elif [[ $(7z l -ba "${romzip}" | grep system | grep chunk | grep -v ".*\.so$") ]]; then
    echo "chunk detected"
    for partition in $PARTITIONS; do
        foundpartitions=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "$partition".img)
        7z e -y "${romzip}" *"$partition"*chunk* */*"$partition"*chunk* "$foundpartitions" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
        rm -f *"$partition"_b*
        rm -f *"$partition"_other*
        romchunk=$(ls | grep chunk | grep "$partition" | sort)
        if [[ $(echo "$romchunk" | grep "sparsechunk") ]]; then
            $simg2img $(echo "$romchunk" | tr '\n' ' ') "$partition".img.raw 2>/dev/null
            rm -rf *"$partition"*chunk*
            if [[ -f $partition.img ]]; then
                rm -rf "$partition".img.raw
            else
                mv "$partition".img.raw "$partition".img
            fi
        fi
    done
elif [[ $(7z l -ba "${romzip}" | grep "super.img") ]]; then
    echo "super detected"
    foundsupers=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "super.img")
    7z e -y "${romzip}" "$foundsupers" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
    superchunk=$(ls | grep chunk | grep super | sort)
    if [[ $(echo "$superchunk" | grep "sparsechunk") ]]; then
        $simg2img $(echo "$superchunk" | tr '\n' ' ') super.img.raw 2>/dev/null
        rm -rf *super*chunk*
    fi
    superimage
elif [[ $(7z l -ba "${romzip}" | gawk '{print $NF}' | grep "system_new.img\|^system.img\|\/system.img\|\/system_image.emmc.img\|^system_image.emmc.img") ]]; then
    echo "Image detected"
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/ -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1 # removes space from file name
    find "$tmpdir"/ -mindepth 2 -type f -name "*_image.emmc.img" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir"/ -mindepth 2 -type f -name "*_new.img" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir"/ -mindepth 2 -type f -name "*.img.ext4" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir"/ -mindepth 2 -type f -name "*.img" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir"/ -type f ! -name "*img*" -exec rm -rf {} \; # delete other files
    find "$tmpdir" -maxdepth 1 -type f -name "*_image.emmc.img" | rename 's/_image.emmc.img/.img/g' > /dev/null 2>&1 # proper .img names
    find "$tmpdir" -maxdepth 1 -type f -name "*_new.img" | rename 's/_new.img/.img/g' > /dev/null 2>&1 # proper .img names
    find "$tmpdir" -maxdepth 1 -type f -name "*.img.ext4" | rename 's/.img.ext4/.img/g' > /dev/null 2>&1 # proper .img names
    romzip=""
elif [[ $(7z l -ba "${romzip}" | grep "system.sin\|.*system_.*\.sin") ]]; then
    echo "sin detected"
    to_remove=$(7z l "${romzip}" | grep ".*boot_.*\.sin" | gawk '{ print $6 }' | sed -e 's/boot_\(.*\).sin/\1/')
    if [ -z "$to_remove" ]
    then
      to_remove=$(7z l "${romzip}" | grep ".*cache_.*\.sin" | gawk '{ print $6 }' | sed -e 's/cache_\(.*\).sin/\1/')
    fi
    if [ -z "$to_remove" ]
    then
      to_remove=$(7z l "${romzip}" | grep ".*vendor_.*\.sin" | gawk '{ print $6 }' | sed -e 's/vendor_\(.*\).sin/\1/')
    fi
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/ -mindepth 2 -type f -name "*.sin" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir" -maxdepth 1 -type f -name "*_$to_remove.sin" | rename 's/_'"$to_remove"'.sin/.sin/g' > /dev/null 2>&1 # proper names
    $unsin -d "$tmpdir"
    find "$tmpdir" -maxdepth 1 -type f -name "*.ext4" | rename 's/.ext4/.img/g' > /dev/null 2>&1 # proper names
    foundsuperinsin=$(find "$tmpdir" -maxdepth 1 -type f -name "super_*.img")
    if [ ! -z "$foundsuperinsin" ]; then
        mv $(ls "$tmpdir"/super_*.img) "$tmpdir/super.img"
        echo "super image inside a sin detected"
        superimage
    fi
    romzip=""
elif [[ $(7z l -ba "${romzip}" | grep ".pac$") ]]; then
    echo "pac detected"
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/ -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1
    pac_list=$(find "$tmpdir"/ -type f -name "*.pac" -printf '%P\n' | sort)
    for file in $pac_list; do
        python3 "$pacextractor" "$file" "$PWD"
    done
    if [[ -f super.img ]]; then
        superimage
    fi
elif [[ $(7z l -ba "${romzip}" | grep "system.bin") ]]; then
    echo "bin images detected"
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/ -mindepth 2 -type f -name "*.bin" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir" -maxdepth 1 -type f -name "*.bin" | rename 's/.bin/.img/g' > /dev/null 2>&1 # proper names
    romzip=""
elif [[ $(7z l -ba "${romzip}" | grep "system-p") ]]; then
    echo "P suffix images detected"
    for partition in $PARTITIONS; do
        foundpartitions=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "$partition"-p)
        7z e -y "${romzip}" "$foundpartitions" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
        if [ ! -z "$foundpartitions" ]; then
            mv $(ls "$partition"-p*) "$partition.img"
        fi
    done
elif [[ $(7z l -ba "${romzip}" | grep "system-sign.img") ]]; then
    echo "sign images detected"
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    for partition in $PARTITIONS; do
        [[ -e "$tmpdir/$partition.img" ]] && mv "$tmpdir/$partition.img" "${outdir}/$partition.img"
    done
    find "$tmpdir"/ -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1 # removes space from file name
    find "$tmpdir"/ -mindepth 2 -type f -name "*-sign.img" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir"/ -type f ! -name "*-sign.img" -exec rm -rf {} \; # delete other files
    find "$tmpdir" -maxdepth 1 -type f -name "*-sign.img" | rename 's/-sign.img/.img/g' > /dev/null 2>&1 # proper .img names
    sign_list=$(find "$tmpdir" -maxdepth 1 -type f -name "*.img" -printf '%P\n' | sort)
    for file in $sign_list; do
        rm -rf "$tmpdir/x.img"
        MAGIC=$(head -c4 "$tmpdir/$file" | tr -d '\0')
        if [[ $MAGIC == "SSSS" ]]
        then
            echo Cleaning "$file" with SSSS header
            # This is for little_endian arch
            offset_low=$(od -A n -x -j 60 -N 2 "$tmpdir/$file" | sed 's/ //g')
            offset_high=$(od -A n -x -j 62 -N 2 "$tmpdir/$file" | sed 's/ //g')
            offset_low=0x${offset_low:0-4}
            offset_high=0x${offset_high:0-4}
            offset_low=$(printf "%d" "$offset_low")
            offset_high=$(printf "%d" "$offset_high")
            offset=$((65536*${offset_high}+${offset_low}))
            dd if="$tmpdir/$file" of="$tmpdir/x.img" iflag=count_bytes,skip_bytes bs=8192 skip=64 count=$offset > /dev/null 2>&1
        else # header with BFBF magic or another unknowed header
            dd if="$tmpdir/$file" of="$tmpdir/x.img" bs=$((0x4040)) skip=1 > /dev/null 2>&1
        fi
        MAGIC=$(od -A n -X -j 0 -N 4 "$tmpdir/x.img" | sed 's/ //g')
        if [[ $MAGIC == "ed26ff3a" ]]; then
            $simg2img "$tmpdir/x.img" "$tmpdir/$file" > /dev/null 2>&1
        else
            mv "$tmpdir/x.img" "$tmpdir/$file"
        fi
    done
    romzip=""
elif [[ $(7z l -ba "${romzip}" | grep tar.md5 | gawk '{ print $NF }' | grep AP_) ]]; then
    echo "AP tarmd5 detected"
    echo "Extracting tarmd5"
    7z e -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    echo "Extracting images..."
    for i in $(ls *.tar.md5); do
        tar -xf "$i" || exit 1
        rm -fv "$i" || exit 1
        echo "Extracted $i"
    done
    for f in $(ls *.lz4); do
        lz4 -dc "$f" > "${f/.lz4/}" || exit 1
        rm -fv "$f" || exit 1
        echo "Extracted $f"
    done
    if [[ -f super.img ]]; then
        superimage
    fi
    if [[ -f system.img.ext4 ]]; then
        find "$tmpdir" -maxdepth 1 -type f -name "*.img.ext4" | rename 's/.img.ext4/.img/g' > /dev/null 2>&1
    fi
    if [[ ! -f system.img ]]; then
        echo "Extract failed"
        rm -rf "$tmpdir"
        exit 1
    fi
    romzip=""
elif 7z l -ba "${romzip}" | grep -q ./"*.tar"; then
    echo "[INFO] Non-AP tar detected"

    # Extract '.tar' content
    TAR=$(7z l -ba "${romzip}" | grep ./"*.tar" | gawk '{ print $NF }')
    7z e -y "${romzip}" "${TAR}" 2>/dev/null >> "${tmpdir}"/zip.log

    "${LOCALDIR}/extractor.sh" "${TAR}" "${outdir}"
    exit
elif [[ $(7z l -ba "${romzip}" | grep payload.bin) ]]; then
    # Copy 'payload.bin' to our directory
    7z x -y "${romzip}" payload.bin 2>/dev/null >> "${tmpdir}"/zip.log

    # Extract content to our directory
    echo "[INFO] Extracting 'payload.bin' partitions..."
    ${otadump} -o "${tmpdir}" "${PWD}/payload.bin" 2>/dev/null ||
        echo "[ERROR] Failed extracting partitions."

    for p in ${PARTITIONS}; do
        [[ -e "${tmpdir}/${p}.img" ]] && \
            mv "${tmpdir}/${p}.img" "${outdir}/${p}.img"
    done

    # Remove temporary files
    [[ -f "payload.bin" ]] && rm "${PWD}/payload.bin"
    rm -rf "$tmpdir"

    exit
elif [[ $(7z l -ba "${romzip}" | grep ".*.rar\|.*.zip") ]]; then
    echo "Image zip firmware detected"
    mkdir -p "$tmpdir"/zipfiles
    7z e -y "${romzip}" -o"$tmpdir"/zipfiles 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/zipfiles -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1
    zip_list=$(find "$tmpdir"/zipfiles -type f -size +300M \( -name "*.rar*" -o -name "*.zip*" \) -printf '%P\n' | sort)
    for file in $zip_list; do
       "$LOCALDIR/extractor.sh" "$tmpdir"/zipfiles/"$file" "${outdir}"
    done
    exit
elif [[ $(7z l -ba "${romzip}" | grep "UPDATE.APP") ]]; then
    echo "Huawei UPDATE.APP detected"
    7z x "${romzip}" UPDATE.APP
    python3 "$splituapp" -f "UPDATE.APP" -l super preas preavs || (
    for partition in $PARTITIONS; do
        python3 "$splituapp" -f "UPDATE.APP" -l "${partition/.img/}" || echo "$partition not found in UPDATE.APP"
    done)
    if [ -f super.img ]; then
        ($simg2img super.img super_* super.img.raw || mv super.img super.img.raw) 2>/dev/null

        for partition in $PARTITIONS; do
            ($lpunpack --partition="$partition"_a super.img.raw || $lpunpack --partition="$partition" super.img.raw) 2>/dev/null
            if [ -f "$partition"_a.img ]; then
                mv "$partition"_a.img "$partition".img
            else
                foundpartitions=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "$partition".img)
                7z e -y "${romzip}" "$foundpartitions" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
            fi
        done
        rm -rf super.img.raw
    fi
fi

for partition in $PARTITIONS; do
    if [ -f "$partition".img ]; then
        $simg2img "$partition".img "${outdir}"/"$partition".img 2>/dev/null
    fi
    if [[ ! -s "${outdir}"/$partition.img ]] && [ -f "$partition".img ]; then
        mv "$partition".img "${outdir}"/"$partition".img
    fi

    if [[ $EXT4PARTITIONS =~ (^|[[:space:]])"$partition"($|[[:space:]]) ]] && [ -f "${outdir}"/"$partition".img ]; then
        MAGIC=$(head -c12 "${outdir}"/"$partition".img | tr -d '\0')
        offset=$(LANG=C grep -aobP -m1 '\x53\xEF' "${outdir}"/"$partition".img | head -1 | gawk '{print $1 - 1080}')
        if [[ $(echo "$MAGIC" | grep "MOTO") ]]; then
            if [[ "$offset" == 128055 ]]; then
                offset=131072
            fi
            echo "MOTO header detected on $partition in $offset"
        elif [[ $(echo "$MAGIC" | grep "ASUS") ]]; then
            echo "ASUS header detected on $partition in $offset"
        else
            offset=0
        fi
        if [ ! "$offset" == "0" ]; then
            dd if="${outdir}"/"$partition".img of="${outdir}"/"$partition".img-2 ibs="$offset" skip=1 2>/dev/null
            mv "${outdir}"/"$partition".img-2 "${outdir}"/"$partition".img
        fi
    fi

    if [ ! -s "${outdir}"/"$partition".img ] && [ -f "${outdir}"/"$partition".img ]; then
        rm "${outdir}"/"$partition".img
    fi
done

# Specifically check if input is 'radio.img'
if $(7z l -ba "${romzip}" | grep -q radio.img); then
    ## Extract 'radio.img' from archive'
    echo "[INFO] Extracting 'radio.img'..."
    7z x "${romzip}" radio.img -o"${PWD}" >> "$tmpdir"/zip.log

    ## Check if this comes from motorola
    if [[ $(head -c15 "${PWD}"/radio.img) == "SINGLE_N_LONELY" ]]; then
        ## Extract 'radio.img.sparse'
        "${star}" "${PWD}/radio.img" "${PWD}" 2>/dev/null

        ## Delete everything that's not 'NON-HLOS.bin' and 'fsg.mbn'
        find "${PWD}/" -type f ! -name 'NON-HLOS.bin' -and ! -name 'fsg.mbn' -delete
        mv "${PWD}"/fsg.mbn "${outdir}"/fsg.mbn

        ## Move 'NON-HLOS.bin' to 'radio.img.sparse'
        mv "${PWD}/NON-HLOS.bin" "${PWD}/radio.img.sparse"

        ## Convert from sparse to RAW
        ${simg2img} "${PWD}/radio.img.sparse" "${outdir}/radio.img" 2>/dev/null

        ## Remove old sparsed image
        rm -rf "${PWD}"/radio.img.sparse
    fi
fi

cd "$LOCALDIR" || exit
rm -rf "$tmpdir"
