from io import BytesIO
from pathlib import Path
from struct import  unpack
from argparse import ArgumentParser
from typing import List

MAGIC = b'\x55\xAA\x5A\xA5'

CHUNK_SIZE = 0x400  # 1024 bytes
ALIGNMENT = 4  # Alignment bytes

class Partition:
    def __init__(self, start: int, hdr_sz: int, unk1: int, hw_id: int, seq: int,
                 size: int, date: str, time: str, ftype: str, blank1: bytes,
                 hdr_crc: int, block_size: int, blank2: bytes, checksum: bytes,
                 data: bytes, end: int):
        self.start = start
        self.hdr_sz = hdr_sz
        self.unk1 = unk1
        self.hw_id = hw_id
        self.seq = seq
        self.size = size
        self.date = date
        self.time = time
        self.type = ftype
        self.blank1 = blank1
        self.hdr_crc = hdr_crc
        self.block_size = block_size
        self.blank2 = blank2
        self.checksum = checksum
        self.data = data
        self.end = end

    @classmethod
    def from_file(cls, file, offset: int = 0):
        hdr_sz, unk1, hw_id, seq, size = unpack('<LLQLL', file.read(24))
        date, time, type = file.read(16).decode().strip('\x00'), \
            file.read(16).decode().strip('\x00'), file.read(16).decode().strip('\x00')
        blank1, hdr_crc, block_size, blank2, checksum = file.read(16), file.read(2).hex(), \
            file.read(2).hex(), file.read(2), file.read(hdr_sz - 98)

        data = file.read(size) if size > 0 else b''

        file.seek((ALIGNMENT - file.tell() % ALIGNMENT) % ALIGNMENT, 1)
        return cls(offset, hdr_sz, unk1, hw_id, seq, size, date, time, type, blank1,
                   hdr_crc, block_size, blank2, checksum, data, file.tell())

class UpdateExtractor:
    def __init__(self, package: Path, output: Path):
        self.package = package.open('rb')
        self.output = output
        self.partitions: List[Partition] = []

        self.parse_partitions()

    def parse_partitions(self):
        while True:
            buffer = self.package.read(4)
            if not buffer: break

            if buffer == MAGIC:
                self.partitions.append(Partition.from_file(
                    self.package, self.package.tell()
                ))

    def extract(self, name: str = None):
        self.output.mkdir(exist_ok=True)
        for partition in self.partitions:
            if name is not None and partition.type != name:
                continue
            with open('%s/%s.img' % (self.output,
                    partition.type), 'wb') as f:
                f.write(partition.data)

def main():
    parser = ArgumentParser()
    parser.add_argument('package', help='UPDATE.APP package.', type=Path)
    parser.add_argument('-e', '--extract', help='Extract partitions to files.', action='store_true')
    parser.add_argument('-o', '--output', help='Output folder.', default='output', type=Path)
    parser.add_argument('-p', '--partition', help='Partition name to extract.', type=str, default=None)
    args = parser.parse_args()

    extractor = UpdateExtractor(
        args.package, args.output)

    for partition in extractor.partitions:
        print("%s (%d bytes) @ %s - %s" % (partition.type, partition.size,
                                           hex(partition.start), hex(partition.end)))

    if args.extract:
        extractor.extract(args.partition)

if __name__ == '__main__':
    main()
