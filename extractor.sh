#/bin/bash

# Supported Firmwares:
# Aonly OTA
# Raw image
# tarmd5
# chunk image
# QFIL
# AB OTA
# Image zip

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
HOST="$(uname)"
toolsdir="$LOCALDIR/tools"
simg2img="$toolsdir/$HOST/bin/simg2img"
packsparseimg="$toolsdir/$HOST/bin/packsparseimg"
payload_extractor="$toolsdir/update_payload_extractor/extract.py"
sdat2img="$toolsdir/sdat2img.py"
fixmoto="$toolsdir/fixmoto.py"

romzip="$(realpath $1)"
PARTITIONS="system vendor cust odm oem modem dtbo boot"
EXT4PARTITIONS="system vendor cust odm oem"

echo "Create Temp and out dir"
tmpdir="$LOCALDIR/tmp"
outdir="$LOCALDIR/out"
if [ ! "$2" == "" ]; then
	outdir="$(realpath $2)"
fi
mkdir -p "$tmpdir"
mkdir -p "$outdir"

cd $tmpdir

if [[ ! $(7z l $romzip | grep ".*system.ext4.tar.*\|.*tar.md5\|.*chunk\|system\/build.prop\|system.new.dat\|system_new.img\|system.img\|payload.bin\|image.*.zip\|.*system_.*" | grep -v ".*chunk.*\.so$") ]]; then
	echo "BRUH: This type of firmwares not supported"
	exit 1
fi

if [[ $(7z l $romzip | grep system.new.dat) ]]; then
	echo "Aonly OTA detected"
	for partition in $PARTITIONS; do
		7z e $romzip $partition.new.dat* $partition.transfer.list
		cat $partition.new.dat.{0..999} 2>/dev/null >> $partition.new.dat
		cat $partition.new.dat.br.{0..999} 2>/dev/null >> $partition.new.dat
		rm -rf $partition.new.dat.{0..999} $partition.new.dat.br.{0..999}
	done
	ls | grep "\.new\.dat" | while read i; do
		line=$(echo "$i" | cut -d"." -f1)
		if [[ $(echo "$i" | grep "\.dat\.xz") ]]; then
			7z e "$i"
			rm -rf "$i"
		fi
		if [[ $(echo "$i" | grep "\.dat\.br") ]]; then
			echo "$bluet$t_extract_convert_br$normal"
			brotli -d "$i"
			rm -f "$i"
		fi
		echo "Extracting $partition"
		python3 $sdat2img $line.transfer.list $line.new.dat "$outdir"/$line.img
		rm -rf $line.transfer.list $line.new.dat
	done
	cd "$outdir"
	for partition in $PARTITIONS; do
		7z e $romzip $partition.img
		if [ ! -s $partition.img ]; then
			rm $partition.img
		fi
	done
	exit
elif [[ $(7z l $romzip | grep "system_new.img\|system.img$") ]]; then
	echo "Image detected"
	for partition in $PARTITIONS; do
		7z e $romzip $partition_new.img $partition.img
		if [[ -f $partition_new.img ]]; then
			mv $partition_new.img $partition.img
		fi
	done
	romzip=""
elif [[ $(7z l $romzip | grep tar.md5) && ! $(7z l $romzip | grep tar.md5 | gawk '{ print $6 }' | grep AP_) ]]; then
	tarmd5=$(7z l $romzip | grep tar.md5 | gawk '{ print $6 }')
	echo "non AP tarmd5 detected"
	7z e $romzip $tarmd5
	echo "Extracting images..."
	for partition in $PARTITIONS; do
		if [[ $(tar -tf $tarmd5 | grep $partition.img.ext4) ]]; then
			tar -xf $tarmd5 $partition.img.ext4
			mv $partition.img.ext4 $partition.img
		elif [[ $(tar -tf $tarmd5 | grep $partition.img) ]]; then
			tar -xf $tarmd5 $partition.img
		fi
	done
	if [[ -f system.img ]]; then
		rm -rf $tarmd5
	else
		echo "y u bully me!"
		cd "$LOCALDIR"
		rm -rf "$tmpdir"
		exit 1
	fi
	romzip=""
elif [[ $(7z l $romzip | grep tar.md5 | gawk '{ print $6 }' | grep AP_) ]]; then
	echo "AP tarmd5 detected"
	mainmd5=$(7z l $romzip | grep tar.md5 | gawk '{ print $6 }' | grep AP_)
	cscmd5=$(7z l $romzip | grep tar.md5 | gawk '{ print $6 }' | grep CSC_)
	echo "Extracting tarmd5"
	7z e $romzip $mainmd5 $cscmd5
	mainmd5=$(7z l $romzip | grep tar.md5 | gawk '{ print $6 }' | grep AP_ | rev | cut -d "/" -f 1 | rev)
	cscmd5=$(7z l $romzip | grep tar.md5 | gawk '{ print $6 }' | grep CSC_ | rev | cut -d "/" -f 1 | rev)
	echo "Extracting images..."
	for i in "$mainmd5" "$cscmd5"; do
		for partition in $PARTITIONS; do
			tarulist=$(tar -tf $i | grep -e ".*$partition.*\.img.*\|.*$partition.*ext4")
			echo "$tarulist" | while read line; do
				tar -xf "$i" "$line"
				if [[ $(echo "$line" | grep "\.lz4") ]]; then
					lz4 "$line"
					rm -f "$line"
					line=$(echo "$line" | sed 's/\.lz4$//')
				fi
				if [[ $(echo "$line" | grep "\.ext4") ]]; then
					mv "$line" "$(echo "$line" | cut -d'.' -f1).img"
				fi
			done
		done
	done
	if [[ -f system.img ]]; then
		rm -rf $mainmd5
		rm -rf $cscmd5
	else
		echo "Extract failed"
		exit 1
	fi
	romzip=""
elif [[ $(7z l $romzip | grep chunk | grep -v ".*\.so$") ]]; then
	echo "chunk detected"
	for partition in $PARTITIONS; do
		7z e $romzip *$partition*chunk* */*$partition*chunk* $partition.img
		rm -f *system_b*
		romchunk=$(ls | grep chunk | sort)
		if [[ $(echo "$romchunk" | grep "sparsechunk") ]]; then
			$simg2img $(echo "$romchunk" | tr '\n' ' ') $partition.img.raw
			rm -rf *chunk*
			echo "Fix if moto images"
			python3 $fixmoto $partition.img.raw $partition.img
			if [[ -f $partition.img ]]; then
				rm -rf $partition.img.raw
			else
				mv $partition.img.raw $partition.img
			fi
		else
			$simg2img *chunk* $partition.img
			rm -rf *chunk*
		fi
		mv "$partition.img" "$outdir/$partition.img"
	done
	exit
elif [[ $(7z l $romzip | grep rawprogram) ]]; then
	echo "QFIL detected (FIXME: This can only extract system properly)"
	rawprograms=$(7z l $romzip | gawk '{ print $6 }' | grep rawprogram)
	7z e $romzip $rawprograms
	for partition in $PARTITIONS; do
		partitionsonzip=$(7z l $romzip | gawk '{ print $6 }' | grep $partition)
		7z e $romzip $partitionsonzip
		rawprogramsfile=$(grep -rlw $partition rawprogram*)
		$packsparseimg -t $partition -x $rawprogramsfile
		mv "$partition.raw" "$partition.img"
	done
elif [[ $(7z l $romzip | grep payload.bin) ]]; then
	echo "AB OTA detected"
	7z e $romzip payload.bin
	for partition in $PARTITIONS; do
		python $payload_extractor payload.bin --partitions $partition --output_dir $tmpdir
		if [[ -f "$tmpdir/$partition" ]]; then
			mv "$tmpdir/$partition" "$outdir/$partition.img"
		fi
	done
	rm payload.bin
	exit
elif [[ $(7z l $romzip | grep "image.*.zip") ]]; then
	echo "Image zip firmware detected"
	thezip=$(7z l $romzip | grep "image.*.zip" | gawk '{ print $6 }')
	7z e $romzip $thezip
	thezipfile=$(echo $thezip | rev | cut -d "/" -f 1 | rev)
	mv $thezipfile temp.zip
	"$LOCALDIR/extractor.sh" temp.zip "$outdir"
	exit
fi

for partition in $PARTITIONS; do
	$simg2img $partition.img "$outdir"/$partition.img 2>/dev/null
	if [[ ! -s "$outdir"/$partition.img ]] && [ -f $partition.img ]; then
		mv $partition.img "$outdir"/$partition.img
	fi

	if [[ $EXT4PARTITIONS =~ (^|[[:space:]])"$partition"($|[[:space:]]) ]] && [ -f $partition.img ]; then
		offset=$(LANG=C grep -aobP -m1 '\x53\xEF' "$outdir"/$partition.img | head -1 | gawk '{print $1 - 1080}')
		if [ ! $offset == "0" ]; then
			echo "Header detected on $partition"
			dd if="$outdir"/$partition.img of="$outdir"/$partition.img-2 ibs=$offset skip=1 2>/dev/null
			mv "$outdir"/$partition.img-2 "$outdir"/$partition.img
		fi
	fi

	if [ ! -s "$outdir"/$partition.img ]; then
		rm "$outdir"/$partition.img
	fi
done

cd "$LOCALDIR"
rm -rf "$tmpdir"
