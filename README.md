# Extract given archive to images (`Firmware_extractor`)
This repository is used mainly by `dumpyara` in order to pull all images from an archive and easily extract them to directories.

Main objective of this project is so transform files from different manufacturers to simple EXT2 (or similar) images, in order to extract them via `7z` or any other unarchiving program.

## Set-up
As previously mentioned, this is supposed to be ran in-line with `dumpyara`. The needed packages are already installed by the `setup.sh` script [here](https://github.com/AndroidDumps/dumpyara/blob/master/setup.sh), but you might aswell run thse commands individually and execute the script standalone;
```
$ sudo apt install unace unrar zip unzip p7zip-full p7zip-rar sharutils rar uudeview mpack arj cabextract rename liblzma-dev python-pip brotli lz4 protobuf-compiler git gawk
$ pip install backports.lzma protobuf pycrypto twrpdtgen extract-dtb pycryptodome
```

## How to use
### Download
Download, through `git`, the repository to your directory of choice.
```
git clone --recurse-submodules https://github.com/AndroidDumps/Firmware_extractor.git
```

### Extract images from firmware URL
Beforehand, make sure you're gonna to extract an archive we support. You can check the complete list [below](#supported-firmwares). The output with all the extracted images will be displayed on the folder of your choice or, if not specified, to the `out/` directory.

```
$ cd Firmware_extractor
$ wget https://dl.google.com/dl/android/aosp/walleye-pq3a.190705.001-factory-cc471c8c.zip -o firmware.zip
$ ./extractor.sh firmware.zip walleye/
```

#### Syntax
```bash
Usage: ./extractor.sh {firmware.zip} [firmware/]
        {firmware.zip}: path to the archive
        [firmware/]: directory of choice to extract all images to
```

## Supported firmware(s)
 * A-only over-the-air update packages
 * A/B over-the-air update packages
    - Un-zipped packages (plain `payload.bin`)
 * RAW image(s)
     - Un-zipped packages (plain `super.img`)
 * Samsung's archives (`.tar.md5`)
 * Chunk image(s)
 * QFIL packages
 * Archive with image(s)
 * OPPO's archives (`.ozip`)
 * Sony's upgrade packages (`.tft`)
 * ZTE `update.zip`
 * KDDI's `.bin`
 * Archive as binary (`.bin`)
 * Unisoc's upgrade packages (`.pac`)
     - Un-zipped packages (plain `[...].pac`)
 * sign, along with *auth DA*, images (`[...]-sign.img`)
 * Nokia's upgrade packages (`.nb0`)
 * LG's update packages (`.kdz`)
 * HTC's proprietary upgrade packages (RUU)
 * Amlogic's upgrade packages
 * Rockchip's upgrade packages
