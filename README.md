## Requirements
- protobuf
- LZMA
- 7z
- lz4
### Linux
```
apt install liblzma-dev python-pip brotli lz4
pip install backports.lzma protobuf pycrypto
```
### Mac
```
brew install protobuf liblzma-dev brotli lz4
pip install backports.lzma protobuf pycrypto
```

## How to use
### Download
```
git clone --recurse-submodules https://github.com/erfanoabdi/Firmware_extractor.git
```

### Extract images from firmware URL
Example: Extracting images from pixel 2 factory image:
```
cd Firmware_extractor
wget https://dl.google.com/dl/android/aosp/walleye-pq3a.190705.001-factory-cc471c8c.zip -o firmware.zip
./extractor.sh firmware.zip
```
output will be on "Firmware_extractor/out"
