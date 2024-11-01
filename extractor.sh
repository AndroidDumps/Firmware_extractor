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
# super.img
# payload.bin

shopt -s extglob

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

# payload: Extract 'payload.bin'
payload() {
    echo "[INFO] A/B package detected"

    # Extract content to our directory
    echo "[INFO] Extracting 'payload.bin' partitions..."
    ${otadump} --list "${romzip}"
    ${otadump} -o "${tmpdir}" "${romzip}" 2>/dev/null ||
        echo "[ERROR] Failed extracting partitions."
}

# unisoc: Extract '.pac' packages
unisoc() {
    echo "[INFO] Unisoc package detected"

    # Extract '.pac' to our directory, and sanitize image(s)
    if echo "${romzip}" | grep -q ".pac$"; then
        cp "${romzip}" "${tmpdir}"
        find "${tmpdir}" -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1
    else
        7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
        find "${tmpdir}" -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1
    fi

    # Extract (all) found '.pac' package(s) 
    PAC=$(find "$tmpdir"/ -type f -name "*.pac" -printf '%P\n' | sort)
    for f in ${PAC}; do python3 "${pacextractor}" "${f}" "${PWD}" > /dev/null; done

    if [ -f super.img ]; then
        echo "[INFO] Extracting 'super.img'..."
        superimage
    fi
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
echo "[INFO] Cloning or updating submodules..."
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
update_extractor="$toolsdir/update-extractor.py"
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

# Set different directories' path
outdir="${LOCALDIR}/out"
tmpdir="${outdir}/tmp"

# In case a different output directory was chosen
if [ -n "${2}" ]; then
    [ ! -d "${2}" ] && mkdir "${2}"
    outdir="$(realpath "$2")"
fi

# Create all necessary directories
mkdir -p "${tmpdir}" "${outdir}"

# Change directory to working folder
cd "${tmpdir}" || exit

# Simple images support
if echo "${romzip}" | grep -q super.img; then
    echo "[INFO] Copying 'super.img' to working directory..."
    cp "${romzip}" "${tmpdir}"
    superimage
elif echo "${romzip}" | grep -q payload.bin; then
    payload
elif echo "${romzip}" | grep -q ".pac$"; then
    unisoc
fi

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
    if 7z l "${tmpdir}/${filename}.zip" | grep -q system.img; then
        "$LOCALDIR/extractor.sh" "${tmpdir}/${filename}.zip" "${outdir}"
    else
        directory_archive
    fi
    rm -rf "${tmpdir}/${filename}.zip" > /dev/null
    exit
fi

if echo "${romzip}" | grep -q kdz; then
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

if echo "${romzip}" | grep -i ruu_ | grep -qi exe; then
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

if [[ "${romzip}" == *.@(img|bin) ]] && [ "$(head -c6 "${romzip}" | tr '\0' '\n')" == "RKFWf" ]; then
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

if 7z l -ba "${romzip}" 2>/dev/null | grep -q aml; then
    echo "[INFO] Amlogic package detected"
    cp "${romzip}" "${tmpdir}"

    # Extract image(s) from archive
    romzip="${tmpdir}/$(basename "${romzip}")"
    echo "[INFO] Extracting archive..."

    # '7z' might not be able to extract '.tar.bz2' directly
    if [[ "$(basename "${romzip}")" == *".tar.bz2" ]]; then
        tar -xvjf "${romzip}" > /dev/null || {
            echo "[ERROR] Archive extraction ('.tar.bz2') failed!"
            exit 1
        }
    else
        7z e -y "${romzip}" >> "$tmpdir"/zip.log || {
            echo "[ERROR] Archive extraction failed!"
            exit 1
        }
    fi

    # Extract through 'aml_extract'
    echo "[IFNO] Extracting through 'aml-upgrade-package-extract'..."
    $aml_extract "$(find . -type f -name "*aml*.img")" || {
        echo "[INFO] Extraction failed!"
        exit 1
    }

    # Replace partitions' extension to '.img'
    rename 's/.PARTITION$/.img/' *.PARTITION
    rename 's/_aml_dtb.img$/dtb.img/' *.img
    rename 's/_a.img/.img/' *.img

    # Generate a 'super.img'
    [[ -f super.img ]] && \
        superimage

    # Move to output directory
    for p in $PARTITIONS; do
        [[ -e "$tmpdir/$p.img" ]] && \
            mv "$tmpdir/$p.img" "${outdir}/$p.img"
    done

    # Clean-up
    rm -rf "$tmpdir"
    exit 0
fi

# Extract firmware partitions
for partition in ${OTHERPARTITIONS}; do
    # Set the names for the partition(s)
    IN=$(echo "$partition" | cut -f 1 -d ":")
    OUT=$(echo "$partition" | cut -f 2 -d ":")

    # Check if partition is present on archive
    if 7z l -ba "${romzip}" 2>/dev/null | grep -q "$IN" > /dev/null && 7z l -na "${romzip}" 2>/dev/null | grep -q "rawprogram"; then
        echo "[INFO] Extracting ${IN}..."

        # Extract to '${outdir}'
        7z x "${romzip}" "${IN}" -so > "${outdir}"/"${IN}".sparse

        # Convert from sparse to RAW image
        $simg2img "${outdir}/${IN}".sparse "${outdir}/${OUT}".img   
        rm -rf "${outdir}/${IN}".sparse
    fi
done

if 7z l -ba "${romzip}" 2>/dev/null | grep -q firmware-update/dtbo.img; then
    7z e -y "${romzip}" firmware-update/dtbo.img 2>/dev/null >> "$tmpdir"/zip.log
fi

if 7z l -ba "${romzip}" 2>/dev/null | grep -q system.new.dat; then
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
            if echo "$i" | grep "\.dat\.xz"; then
                7z e -y "$i" 2>/dev/null >> "$tmpdir"/zip.log
                rm -rf "$i"
            fi
            if echo "$i" | grep "\.dat\.br"; then
                echo "Converting brotli $partition dat to normal"
                brotli -d "$i"
                rm -f "$i"
            fi
            echo "Extracting $partition"
            python3 "$sdat2img" "$line".transfer.list "$line".new.dat "${outdir}"/"$line".img > "$tmpdir"/extract.log
            rm -rf "$line".transfer.list "$line".new.dat
        done
    done
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q rawprogram; then
    echo "[INFO] QFIL package detected"

    # Start extraction on '${PWD}/out/tmp'
    echo "[INFO] Extracing archive..."
    7z e -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log || {
        echo "[ERROR] Archive extraction failed"
        exit 1
    }

    for p in ${PARTITIONS}; do
        # Rename RAW images into normal images
        if [[ -f "$p.raw.img" ]]; then
            mv "$p.raw.img" "$p.img"
        else
            # There might be 'rawprogram_unsparse0.xml', which is preferred
            if [ -f "${PWD}/rawprogram_unsparse0.xml" ]; then
                RAWPROGRAM="${PWD}/rawprogram_unsparse0.xml"
            else
                RAWPROGRAM="$(grep -rlw "${p}" rawprogram*.xml)"
            fi

            # Extract (existing) images via 'packsparseimg'
            if ls "${PWD}" | grep -q "${p}"; then
                echo "[INFO] Extracting '${p}.img' with 'packsparseimg'..."
                "${packsparseimg}" -t "${p}" -x "${RAWPROGRAM}" 2> /dev/null || echo "[WARNING] '${p}.img' extraction failed."
                mv "${p}.raw" "${p}.img" 2>/dev/null
            fi
        fi
    done

    # Execute in case we have a 'super.img'
    if [[ -f super.img ]]; then
        superimage
    fi
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q nb0; then
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
elif 7z l -ba "${romzip}" 2>/dev/null | grep system | grep chunk | grep -qv ".*\.so$"; then
    echo "chunk detected"
    for partition in $PARTITIONS; do
        foundpartitions=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "$partition".img)
        7z e -y "${romzip}" *"$partition"*chunk* */*"$partition"*chunk* "$foundpartitions" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
        rm -f *"$partition"_b*
        rm -f *"$partition"_other*
        romchunk=$(ls | grep chunk | grep "$partition" | sort)
        if echo "$romchunk" | grep -q "sparsechunk"; then
            $simg2img "$(echo "$romchunk" | tr '\n' ' ')" "$partition".img.raw 2>/dev/null
            rm -rf *"$partition"*chunk*
            if [[ -f $partition.img ]]; then
                rm -rf "$partition".img.raw
            else
                mv "$partition".img.raw "$partition".img
            fi
        fi
    done
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q "super.img"; then
    echo "super detected"
    foundsupers=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "super.img")
    7z e -y "${romzip}" "$foundsupers" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
    superchunk=$(ls | grep chunk | grep super | sort)
    if echo "$superchunk" | grep -q "sparsechunk"; then
        $simg2img "$(echo "$superchunk" | tr '\n' ' ')" super.img.raw 2>/dev/null
        rm -rf *super*chunk*
    fi
    superimage
elif 7z l -ba "${romzip}" 2>/dev/null | gawk '{print $NF}' | grep "system_new.img\|^system.img\|\/system.img\|\/system_image.emmc.img\|^system_image.emmc.img"; then
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
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q "system.sin\|.*system_.*\.sin"; then
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
    # Extract image(s) from archive
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log

    find "$tmpdir"/ -mindepth 2 -type f -name "*.sin" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir" -maxdepth 1 -type f -name "*_$to_remove.sin" | rename 's/_'"$to_remove"'.sin/.sin/g' > /dev/null 2>&1 # proper names
    $unsin -d "$tmpdir"
    find "$tmpdir" -maxdepth 1 -type f -name "*.ext4" | rename 's/.ext4/.img/g' > /dev/null 2>&1 # proper names

    foundsuperinsin=$(find "$tmpdir" -maxdepth 1 -type f -name "super_*.img")
    if [ -n "$foundsuperinsin" ]; then
        mv "$(ls "$tmpdir"/super_*.img)" "$tmpdir/super.img"
        echo "super image inside a sin detected"
        superimage
    fi
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q ".pac$"; then
    unisoc
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q "system.bin"; then
    echo "bin images detected"
    7z x -y "${romzip}" 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/ -mindepth 2 -type f -name "*.bin" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "$tmpdir" -maxdepth 1 -type f -name "*.bin" | rename 's/.bin/.img/g' > /dev/null 2>&1 # proper names
    romzip=""
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q "system-p"; then
    echo "P suffix images detected"
    for partition in $PARTITIONS; do
        foundpartitions=$(7z l -ba "${romzip}" | gawk '{ print $NF }' | grep "$partition"-p)
        7z e -y "${romzip}" "$foundpartitions" dummypartition 2>/dev/null >> "$tmpdir"/zip.log
        if [ -n "$foundpartitions" ]; then
            mv "$(ls "$partition"-p*)" "$partition.img"
        fi
    done
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q system-sign.img; then
    echo "[INFO] 'sign' images detected"

    # Extract images to '${tmpdir}'
    echo "[INFO] Extracting archive with images..."

    for p in ${PARTITIONS}; do
        SIGN=$(echo "${p}"-sign.img)
        7z x -y "${romzip}" "${SIGN}" 2>/dev/null >> "$tmpdir"/zip.log ||  {
                echo "[ERROR] Failed to extract '${f}'"
                exit 1
            }
    done

    # Prepare temporary directory for cleaning
    find "${tmpdir}"/ -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1 # removes space from file name
    find "${tmpdir}"/ -mindepth 2 -type f -name "*-sign.img" -exec mv {} . \; # move .img in sub-dir to $tmpdir
    find "${tmpdir}"/ -type f ! -name "*-sign.img" -exec rm -rf {} \; # delete other files
    find "${tmpdir}"/ -maxdepth 1 -type f -name "*-sign.img" | rename 's/-sign.img/.img/g' > /dev/null 2>&1 # proper .img names

    # Get a list of signed image(s)
    SIGN=$(find "${tmpdir}" -maxdepth 1 -type f -name "*.img" -printf '%P\n' | sort)

    for f in ${SIGN}; do
        # Achieve magic of the file(s)
        MAGIC=$(head -c4 "${tmpdir}/${f}" | tr -d '\0')

        if [[ $MAGIC == "SSSS" ]]; then
            echo "[INFO] Cleaning '${f}' with SSSS header..."

            # This is for 'little_endian' arch
            offset=$(od -A n -x -j 60 -N 4 "$tmpdir/$f" | sed 's/ //g')
            offset=$((0x${offset:4:4} * 65536 + 0x${offset:0:4}))
            dd if="${tmpdir}/${f}" of="${tmpdir}/${f}.tmp" iflag=count_bytes,skip_bytes bs=8192 skip=64 count=${offset} > /dev/null 2>&1 || {
                echo "[ERROR] Failed to clean '${f}'"
                exit 1
            }
        else 
            echo "[INFO] Cleaning '${f}' with other header..."

            # Header has BFBF magic or other
            dd if="${tmpdir}/${f}" of="${tmpdir}/${f}.tmp" bs=$((0x4040)) skip=1 > /dev/null 2>&1 ||  {
                echo "[ERROR] Failed to clean '${f}'"
                exit 1
            }
        fi

        # If magic matches with spared image, use 'simg2img' over it
        MAGIC=$(od -A n -X -j 0 -N 4 "$tmpdir/${f}.tmp" | sed 's/ //g')
        if [[ $MAGIC == "ed26ff3a" ]]; then
            "${simg2img}" "${tmpdir}/${f}.tmp" "${tmpdir}/${f}" > /dev/null 2>&1 ||  {
                echo "[ERROR] Failed to unsparse '${f}'"
                exit 1
            }
        else
            mv "${tmpdir}/${f}.tmp" "$tmpdir/${f}"
        fi

        # Clean-up
        rm -rf "${tmpdir}/${f}.tmp"
    done
elif 7z l -ba "${romzip}" 2>/dev/null | grep tar.md5 | gawk '{ print $NF }' | grep AP_; then
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
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q "*.tar"; then
    echo "[INFO] Non-AP tar detected"

    # Extract '.tar' content
    TAR=$(7z l -ba "${romzip}" | grep ./"*.tar" | gawk '{ print $NF }')
    7z e -y "${romzip}" "${TAR}" 2>/dev/null >> "${tmpdir}"/zip.log

    "${LOCALDIR}/extractor.sh" "${TAR}" "${outdir}"
    exit
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q payload.bin; then
    payload
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q ".*.rar\|.*.zip"; then
    echo "Image zip firmware detected"
    mkdir -p "$tmpdir"/zipfiles
    7z e -y "${romzip}" -o"$tmpdir"/zipfiles 2>/dev/null >> "$tmpdir"/zip.log
    find "$tmpdir"/zipfiles -name "* *" -type d,f | rename 's/ /_/g' > /dev/null 2>&1
    zip_list=$(find "$tmpdir"/zipfiles -type f -size +300M \( -name "*.rar*" -o -name "*.zip*" \) -printf '%P\n' | sort)
    for file in $zip_list; do
       "$LOCALDIR/extractor.sh" "$tmpdir"/zipfiles/"$file" "${outdir}"
    done
    exit
elif 7z l -ba "${romzip}" 2>/dev/null | grep -q "UPDATE.APP"; then
    echo "[INFO] Huawei 'UPDATE.APP' detected"

    # Gather and extract 'UPDATE.APP' from archive
    7z x "${romzip}" UPDATE.APP >> "$tmpdir"/zip.log
    python "${update_extractor}" -e UPDATE.APP -o "${PWD}" > /dev/null

    # Change partition's name to lowercase
    for f in $(find . -name '*.img'); do
        mv "${f}" "${f,,}"
    done

    # Extract 'super.img' if present
    if [ -f super.img ]; then
        echo "[INFO] Extracting 'super.img'..."
        superimage
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
        if echo "$MAGIC" | grep -q "MOTO"; then
            if [[ "$offset" == 128055 ]]; then
                offset=131072
            fi
            echo "MOTO header detected on $partition in $offset"
        elif echo "$MAGIC" | grep -q "ASUS"; then
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
if 7z l -ba "${romzip}" 2>/dev/null | grep -q radio.img; then
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

if [[ $(ls -A "${outdir}" | wc -l ) -eq 1 ]]; then
    echo "[FAILED] '${outdir}' is empty.
         Are you sure your archive is supported?"
fi

cd "$LOCALDIR" || exit
rm -rf "$tmpdir"
