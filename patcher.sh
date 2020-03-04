#!/usr/bin/env bash

# Supported Firmwares:
# AB OTA

usage() {
    echo "Usage: $0 [--verbose|-v] [--output|-o Output Dir] <Path to base firmware> <path to OTA> [path to OTA2] [path to OTA3]..."
    echo -e "\t[--output|-o Output Dir]: the output dir!"
    echo -e "\t[--verbose|-v]: Verbose mode"
}

LOCALDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLSDIR="$LOCALDIR/tools"
if [[ ! -d "$TOOLSDIR/update_payload_extractor" ]]; then
    git clone -q https://github.com/erfanoabdi/update_payload_extractor.git "$TOOLSDIR/update_payload_extractor"
else
    git -C "$TOOLSDIR/update_payload_extractor" pull
fi
PAYLOAD_EXTRACTOR="$TOOLSDIR/update_payload_extractor/extract.py"
VERBOSE=n
OUTDIR="$LOCALDIR/out"

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    --verbose|-v)
    VERBOSE=y
    shift
    ;;
    --output|-o)
    OUTDIR="$(realpath $2)"
    shift
    shift
    ;;
    --help|-h|-?)
    usage
    exit
    ;;
    *)
    POSITIONAL+=("$1")
    shift
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [[ ! -n $2 ]]; then
    echo "ERROR: Enter all needed parameters"
    usage
    exit
fi

BASE_FIRMWARE="$(realpath $1)"
shift

TMPDIR="$OUTDIR/tmp"
mkdir -p "$TMPDIR"

echo "Extracting Base Firmware"
if [[ "$VERBOSE" = "n" ]]; then
    "$LOCALDIR"/extractor.sh "$BASE_FIRMWARE" "$TMPDIR/source" > /dev/null 2>&1
else
    "$LOCALDIR"/extractor.sh "$BASE_FIRMWARE" "$TMPDIR/source"
fi

for OTA_FILE in $@; do
    ((OTA_NO++))
    echo "Patching OTA Number $OTA_NO"
    if [[ ! $(7z l -ba $OTA_FILE | grep "payload.bin") ]]; then
        echo "$OTA_FILE is bad OTA zip"
        continue
    fi
    7z e -y "$OTA_FILE" "payload.bin" -o"$TMPDIR/" > /dev/null 2>&1
    if [[ "$VERBOSE" = "n" ]]; then
        python "$PAYLOAD_EXTRACTOR" --source_dir "$TMPDIR/source" --output_dir "$TMPDIR/output" "$TMPDIR/payload.bin" > /dev/null 2>&1
    else
        python "$PAYLOAD_EXTRACTOR" --source_dir "$TMPDIR/source" --output_dir "$TMPDIR/output" "$TMPDIR/payload.bin"
    fi
    rm -rf "$TMPDIR/source" "$TMPDIR/payload.bin"
    mv "$TMPDIR/output" "$TMPDIR/source"
done

mv "$TMPDIR/source/"* "$OUTDIR/"
rm -rf "$TMPDIR"
