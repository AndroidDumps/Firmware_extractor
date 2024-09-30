#!/bin/sh

# SPDX-FileCopyrightText: 2023 Hemanth Jabalpuri
# SPDX-License-Identifier: CC0-1.0

# This basic program is used for unpacking Motorola archives which are made using single image tar(star) utility
# can run in dash. dd, od, tr are used mainly(busybox also compatible)
#
# Created : 1st Feb 2023
# Author  : HemanthJabalpuri

if [ $# -lt 2 ]; then
  echo "Usage: star.sh file outdir"
  exit
fi

f="$1"
outdir="$2"

mkdir -p "$outdir" 2>/dev/null

getData() {
  dd if="$f" bs=1 skip=$1 count=$2 2>/dev/null
}

getLong() {
  getData $1 8 | od -A n -t u8 | tr -d " "
}

magic=$(getData 0 15)
if [ "$magic" != "SINGLE_N_LONELY" ]; then
  echo " Unsupported"; exit 1
fi

seekoff=256
for i in $(seq 64); do
  name="$(getData $seekoff 248)"
  [ "$name" = "LONELY_N_SINGLE" ] && break
  length="$(getLong $((seekoff+248)))"
  offset="$((seekoff+256))"
  pad=$((length%4096))
  [ "$pad" -ne 0 ] && pad=$((4096-pad))
  echo "Name: $name, Offset: $offset, Size: $length, Padding: $pad"

  dd if="$f" of="$outdir/$name" iflag=skip_bytes,count_bytes status=none bs=4096 skip=$offset count=$length
  seekoff="$((offset+length+pad))"
done
