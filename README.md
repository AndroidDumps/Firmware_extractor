## Requirements
- protobuf
- LZMA
- 7z
- lz4

### Linux
```
apt install unace unrar zip unzip p7zip-full p7zip-rar sharutils rar uudeview mpack arj cabextract rename liblzma-dev python-pip brotli lz4 protobuf-compiler git gawk
pip install backports.lzma protobuf pycrypto twrpdtgen extract-dtb pycryptodome
```

## How to use
### Download
```
git clone --recurse-submodules https://github.com/AndroidDumps/Firmware_extractor.git
```

### Extract images from firmware URL
Example: Extracting images from pixel 2 factory image:
```
cd Firmware_extractor
wget https://dl.google.com/dl/android/aosp/walleye-pq3a.190705.001-factory-cc471c8c.zip -o firmware.zip
./extractor.sh firmware.zip
```
output will be on "Firmware_extractor/out"
