# A simple and correct LG KDZ Android image extractor, because I got fed up
# with the partially working one from kdztools.
#
# Copyright (c) 2021 Isaac Garzon
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

from __future__ import print_function
import io
import os
import errno
import argparse
import struct
import hashlib
import binascii
import datetime
import collections
import zlib
import zstandard


def decode_asciiz(s):
    return s.rstrip(b'\x00').decode('ascii')


def iter_read(file, size, chunk_size):
    while size > 0:
        chunk = file.read(min(chunk_size, size))
        assert len(chunk) > 0
        yield chunk
        size -= len(chunk)


class KdzHeader(object):
    V1_HDR_SIZE = 1304
    V1_MAGIC = 0x50447932
    V2_HDR_SIZE = 1320
    V2_MAGIC = 0x80253134
    V3_HDR_SIZE = 1320
    V3_MAGIC = 0x25223824

    BASE_HDR_FMT = struct.Struct('<II')  # size, magic

    V1_RECORD_FMT = struct.Struct('<256sII')  # name, size, offset
    V1_RECORDS = (V1_RECORD_FMT, V1_RECORD_FMT)  # DZ record, DLL record

    V2_RECORD_FMT = struct.Struct('<256sQQ')  # name, size, offset
    V2_RECORDS = (
        V2_RECORD_FMT, V2_RECORD_FMT,  # DZ record, DLL record
        struct.Struct('<B'),  # b'\x03'
        V2_RECORD_FMT, V2_RECORD_FMT)  # dylib record, unknown record

    V3_ADDITIONAL_RECORD_FMT = struct.Struct('<QI')  # offset, size
    V3_RECORDS = (
        V2_RECORD_FMT, V2_RECORD_FMT,  # DZ record, DLL record
        struct.Struct('<B'),  # b'\x03'
        V2_RECORD_FMT, V2_RECORD_FMT,  # dylib record, unknown record
        struct.Struct('<I5s'),  # extended mem ID size, tag
        struct.Struct('<Q'),  # additional records size
        V3_ADDITIONAL_RECORD_FMT,  # Suffix Map offset, size
        V3_ADDITIONAL_RECORD_FMT,  # SKU Map offset, size
        struct.Struct('<32s'),  # FTM model name
        V3_ADDITIONAL_RECORD_FMT,  # Extended SKU map
    )

    EXTENDED_MEM_ID_OFFSET = 0x14738

    Record = collections.namedtuple('Record', 'name size offset')
    AdditionalRecord = collections.namedtuple('AdditionalRecord', 'offset size')

    def __init__(self, file):
        hdr_data = file.read(self.V3_HDR_SIZE)
        size, magic = self.BASE_HDR_FMT.unpack(hdr_data[:self.BASE_HDR_FMT.size])
        if size == self.V3_HDR_SIZE and magic == self.V3_MAGIC:
            self._parse_v3_header(hdr_data[:self.V3_HDR_SIZE])
        elif size == self.V2_HDR_SIZE and magic == self.V2_MAGIC:
            self._parse_v2_header(hdr_data[:self.V2_HDR_SIZE])
        elif size == self.V1_HDR_SIZE and magic == self.V1_MAGIC:
            self._parse_v1_header(hdr_data[:self.V1_HDR_SIZE])
        else:
            raise ValueError('unknown header (size={}, magic={:x})'.format(
                size, magic))
        self.magic = magic
        self.size = size

    def _parse_v1_header(self, data):
        record_data = io.BytesIO(data[self.BASE_HDR_FMT.size:])
        records = []
        for i, unpacker in enumerate(self.V1_RECORDS):
            (name, size, offset) = unpacker.unpack(record_data.read(unpacker.size))
            name = decode_asciiz(name)
            assert name, 'empty name in record {}'.format(i)
            records.append(self.Record(name, size, offset))
        assert all(p == 0 for p in record_data.read()
            ), 'non-zero byte(s) in record padding'
        self.records = records
        self.version = 1

        # Fill in fields used by other versions
        self.tag = ''
        self.ftm_model_name = ''
        self.additional_records_size = 0
        self.extended_mem_id = self.AdditionalRecord(0, 0)
        self.suffix_map = self.AdditionalRecord(0, 0)
        self.sku_map = self.AdditionalRecord(0, 0)
        self.extended_sku_map = self.AdditionalRecord(0, 0)

    def _parse_v2_header(self, data):
        record_data = io.BytesIO(data[self.BASE_HDR_FMT.size:])
        parsed_records = []
        for i, unpacker in enumerate(self.V2_RECORDS):
            parsed_records.append(unpacker.unpack(record_data.read(unpacker.size)))
        assert all(p == 0 for p in record_data.read()
            ), 'non-zero byte(s) in record padding'
        assert parsed_records[2][0] in (0, 3), 'unexpected byte after DLL record {:x}'.format(parsed_records[2][0])
        del parsed_records[2]
        records = []
        for i, (name, size, offset) in enumerate(parsed_records):
            name = decode_asciiz(name)
            if not name:
                assert size == 0 and offset == 0, 'unnamed record with size {} and offset {}'.format(
                    size, offset)
                continue
            records.append(self.Record(name, size, offset))
        self.records = records
        self.version = 2

        # Fill in fields used by other versions
        self.tag = ''
        self.ftm_model_name = ''
        self.additional_records_size = 0
        self.extended_mem_id = self.AdditionalRecord(0, 0)
        self.suffix_map = self.AdditionalRecord(0, 0)
        self.sku_map = self.AdditionalRecord(0, 0)
        self.extended_sku_map = self.AdditionalRecord(0, 0)

    def _parse_v3_header(self, data):
        record_data = io.BytesIO(data[self.BASE_HDR_FMT.size:])
        parsed_records = []
        for i, unpacker in enumerate(self.V3_RECORDS):
            parsed_records.append(unpacker.unpack(record_data.read(unpacker.size)))
        assert all(p == 0 for p in record_data.read()
            ), 'non-zero byte(s) in record padding'
        assert parsed_records[2][0] in (0, 3), 'unexpected byte after DLL record {:x}'.format(parsed_records[2][0])
        del parsed_records[2]
        additional_records = parsed_records[4:]

        records = []
        for i, (name, size, offset) in enumerate(parsed_records[:4]):
            name = decode_asciiz(name)
            if not name:
                assert size == 0 and offset == 0, 'unnamed record with size {} and offset {}'.format(
                    size, offset)
                continue
            records.append(self.Record(name, size, offset))
        self.records = records

        extended_mem_id_size, self.tag = additional_records[0]
        self.tag = self.tag.rstrip(b'\x00').decode('utf-8')
        self.additional_records_size, = additional_records[1]
        self.extended_mem_id = self.AdditionalRecord(self.EXTENDED_MEM_ID_OFFSET, extended_mem_id_size)
        self.suffix_map = self.AdditionalRecord(*additional_records[2])
        self.sku_map = self.AdditionalRecord(*additional_records[3])
        self.ftm_model_name, = additional_records[4]
        self.ftm_model_name = self.ftm_model_name.rstrip(b'\x00').decode('utf-8')
        self.extended_sku_map = self.AdditionalRecord(*additional_records[5])

        assert self.additional_records_size == (
            self.suffix_map.size + self.sku_map.size + self.extended_sku_map.size), (
            'expected total size of addition records to be {}, got {}'.format(
                self.additional_records_size,
                self.suffix_map.size + self.sku_map.size + self.extended_sku_map.size))

        self.version = 3


class SecurePartition(object):
    OFFSET = 1320
    SIZE = 82448
    MAGIC = 0x53430799
    SIG_SIZE_MAX = 0x200

    # magic, flags, part_count, sig_size, signature
    HDR_FMT = struct.Struct('<IIII{}s'.format(SIG_SIZE_MAX))
    # name, hw part, logical_part?,
    # start sector, end sector, sector count, reserved, hash? (sha256?)
    PART_FMT = struct.Struct('<30sBBIIII32s')
    PART_DATA_SIZE_MAX = SIZE - HDR_FMT.size

    Part = collections.namedtuple(
        'Part', 'name hw_part logical_part start_sect end_sect data_sect_cnt reserved hash')

    def __init__(self, file):
        file.seek(self.OFFSET)
        data = file.read(self.SIZE)
        magic, flags, part_count, sig_size, signature = self.HDR_FMT.unpack(
            data[:self.HDR_FMT.size])
        if magic != self.MAGIC:
            raise ValueError('invalid secure partition magic')
        assert sig_size <= self.SIG_SIZE_MAX, 'signature is too big'
        assert all(p == 0 for p in signature[sig_size:]), 'non-zero byte(s) in signature padding'
        part_data = data[self.HDR_FMT.size:]
        assert (part_count * self.PART_FMT.size) <= len(part_data), 'part_count overflows secure partition size'
        assert all(p == 0 for p in part_data[part_count * self.PART_FMT.size:]), 'non-zero byte(s) in part padding'
        self.parts = collections.OrderedDict()
        for i, part in enumerate(self.PART_FMT.iter_unpack(
                part_data[:part_count * self.PART_FMT.size])):
            name = decode_asciiz(part[0])
            part = self.Part(name, *part[1:])
            assert part.data_sect_cnt > 0, (
                'unexpected empty part @ {} ({})'.format(i, name))
            # Disabled validation because of broken vendor_b partition:
            # assert part.end_sect == 0 or (
            #     part.end_sect >= part.start_sect + part.data_sect_cnt), (
            #         'Unexpected value for end sector {} == {} + {} @ {} ({})'.format(
            #             part.end_sect, part.start_sect, part.data_sect_cnt, i, name))
            assert part.reserved == 0, (
                'unexpected reserved field value {} @ {} ({})'.format(
                    part.reserved, i, name))
            self.parts.setdefault(
                part.hw_part, collections.OrderedDict()).setdefault(
                    name, []).append(part)
        self.magic = magic
        self.flags = flags
        self.signature = signature[:sig_size]


class DzHeader(object):
    MAGIC = 0x74189632
    PART_MAGIC = 0x78951230

    READ_CHUNK_SIZE = 1048576  # 1MiB

    HW_PARTITION_NONE = 0x5000

    HDR_FMT = struct.Struct(
        '<IIII'  # Magic, major, minor, reserved
        '32s'  # model name
        '128s'  # SW version
        'HHHHHHHH'  # build date: year, month, weekday, day, hour, minute, second, millisec
        'I'  # part count
        '16s'  # chunk headers MD5 hash
        'B'  # Secure image type
        '9s'  # compression type: string ('zlib'/'zstd') / byte (1=zlib, 4=zstd)
        '16s'  # data MD5 hash
        '50s'  # SWFV
        '16s'  # Build type
        'I'  # Unknown
        'I'  # Header CRC32
        '10s'  # Android version
        '11s'  # Memory size (string)
        '4s'  # Signed security ('Y' or 'N')
        'I'  # is_ufs
        'I'  # Anti-Rollback version
        '64s'  # Supported Memories list
        '24s'  # Target product
        'B'  # Multi panel bitfield
        'B'  # product_fuse_id (an ASCII digit, sometimes a plain byte in the range 0-9)
        'I'  # Unknown
        'B'  # is_factory_image ('F' if yes)
        '24s'  # Operator code
        'I'  # Unknown
        '44s'  # Padding
        )

    V0_PART_FMT = struct.Struct(
        '<I'  # Magic
        '32s'  # Part name
        '64s'  # Chunk name
        'I'  # Decompressed size
        'I'  # Compressed size
        '16s'  # MD5 hash
        )

    V1_PART_FMT = struct.Struct(
        '<I'  # Magic
        '32s'  # Part name
        '64s'  # Chunk name
        'I'  # Decompressed size
        'I'  # Compressed size
        '16s'  # MD5 hash
        'I'  # Start sector
        'I'  # Sector count
        'I'  # HW partition number
        'I'  # CRC32
        'I'  # Unique part ID
        'I'  # is_sparse
        'I'  # is_ubi_image
        'I'  # Part start sector
        '356s'  # Padding
        )

    Chunk = collections.namedtuple('Chunk',
        'name data_size file_offset file_size hash crc '
        'start_sector sector_count part_start_sector unique_part_id '
        'is_sparse is_ubi_image')

    def __init__(self, file):
        parsed = self.HDR_FMT.unpack(file.read(self.HDR_FMT.size))
        (magic, major, minor, reserved,
            model_name, sw_version,
            build_year, build_mon, build_weekday, build_day,
            build_hour, build_min, build_sec, build_millisec,
            part_count, chunk_hdrs_hash, secure_image_type, compression,
            data_hash, swfv, build_type, unk0, header_crc,
            android_ver, memory_size, signed_security,
            is_ufs, anti_rollback_ver,
            supported_mem, target_product,
            multi_panel_mask, product_fuse_id, unk1,
            is_factory_image, operator_code, unk2, padding) = parsed

        if header_crc != 0:
            calculated_header_crc = binascii.crc32(self.HDR_FMT.pack(
                magic, major, minor, reserved,
                model_name, sw_version,
                build_year, build_mon, build_weekday, build_day,
                build_hour, build_min, build_sec, build_millisec,
                part_count, chunk_hdrs_hash, secure_image_type, compression,
                b'', swfv, build_type, unk0, 0,
                android_ver, memory_size, signed_security,
                is_ufs, anti_rollback_ver,
                supported_mem, target_product,
                multi_panel_mask, product_fuse_id, unk1,
                is_factory_image, operator_code, unk2, padding))

            assert header_crc == calculated_header_crc, (
                'header CRC mismatch: expected {:x}, got {:x}'.format(
                    header_crc, calculated_header_crc))

        if data_hash != b'\xff' * len(data_hash):
            self._verify_data_hash = hashlib.md5(self.HDR_FMT.pack(
                magic, major, minor, reserved,
                model_name, sw_version,
                build_year, build_mon, build_weekday, build_day,
                build_hour, build_min, build_sec, build_millisec,
                part_count, chunk_hdrs_hash, secure_image_type, compression,
                b'\xff' * len(data_hash),
                swfv, build_type, unk0, header_crc,
                android_ver, memory_size, signed_security,
                is_ufs, anti_rollback_ver,
                supported_mem, target_product,
                multi_panel_mask, product_fuse_id, unk1,
                is_factory_image, operator_code, unk2, padding))
        else:
            self._verify_data_hash = None

        assert magic == self.MAGIC, 'invalid DZ header magic'
        assert major <= 2 and minor <= 1, 'unexpected DZ version {}.{}'.format(
            major, minor)
        assert reserved == 0, 'unexpected value for reserved field'
        assert part_count > 0, 'expected positive part count, got {}'.format(
            part_count)

        assert unk0 == 0, 'expected 0 in unknown field, got {}'.format(unk0)
        assert unk1 in (0, 0xffffffff), 'uexpected value in unknown field: {:x}'.format(unk1)
        assert unk2 in (0, 1), 'expected 0 or 1 in unknown field, got {}'.format(unk2)
        assert all(b == 0 for b in padding), 'non zero bytes in header padding'

        self.magic = magic
        self.major = major
        self.minor = minor
        if all(w == 0 for w in (
                build_year, build_mon, build_weekday, build_day,
                build_hour, build_min, build_sec, build_millisec)):
            self.build_date = None
        else:
            self.build_date = datetime.datetime(
                build_year, build_mon, build_day, build_hour, build_min, build_sec,
                microsecond=build_millisec*1000)
            assert self.build_date.weekday() == build_weekday, (
                'invalid build weekday. Expected {}, got {}'.format(
                    self.build_date.weekday(), build_weekday))
        self.compression = self._parse_compression_type(compression)
        self.secure_image_type = secure_image_type
        self.swfv = decode_asciiz(swfv)
        self.build_type = decode_asciiz(build_type)
        self.android_ver = decode_asciiz(android_ver)
        self.memory_size = decode_asciiz(memory_size)
        self.signed_security = decode_asciiz(signed_security)
        self.anti_rollback_ver = anti_rollback_ver
        self.supported_mem = decode_asciiz(supported_mem)
        self.target_product = decode_asciiz(target_product)
        self.operator_code = decode_asciiz(operator_code).split('.')
        self.multi_panel_mask = multi_panel_mask
        self.product_fuse_id = product_fuse_id
        self.is_factory_image = is_factory_image == b'F'
        self.is_ufs = bool(is_ufs)
        self.chunk_hdrs_hash = chunk_hdrs_hash
        self.data_hash = data_hash
        self.header_crc = header_crc

        if self.minor == 0:
            self.parts = self._parse_v0_part_headers(part_count, file)
        else:
            self.parts = self._parse_v1_part_headers(part_count, file)

        if self._verify_data_hash:
            calculated_data_hash = self._verify_data_hash.digest()
            assert self.data_hash == calculated_data_hash, (
                'data hash mismatch: expected {}, got {}'.format(
                    binascii.hexlify(header_hash),
                    binascii.hexlify(calculated_data_hash)))


    def _parse_compression_type(self, compression):
        if compression[1] != 0:
            compression = decode_asciiz(compression).lower()
            assert self.compression in ('zlib', 'zstd'), (
                'unknown compression {}'.format(compression))
        else:
            assert all(b == 0 for b in compression[1:]), (
                'non zero bytes after compression type byte')
            assert compression[0] in (1, 4), (
                'unknown compression type {}'.format(compression[0]))
            if compression[0] == 1:
                compression = 'zlib'
            elif compression[0] == 4:
                compression = 'zstd'
        return compression

    def _parse_v0_part_headers(self, part_count, file):
        parts = collections.OrderedDict()
        verify_hdr_hash = hashlib.md5()
        for i in range(part_count):
            chunk_hdr_data = file.read(self.V0_PART_FMT.size)
            (magic, part_name, chunk_name,
                data_size, file_size, part_hash) = self.V0_PART_FMT.unpack(
                    chunk_hdr_data)
            verify_hdr_hash.update(chunk_hdr_data)
            assert magic == self.PART_MAGIC, (
                'invalid part magic {:x} @ index {}'.format(magic, i))
            assert all(b == 0 for b in padding), (
                'non zero bytes in part padding @ index {}'.format(i))
            assert data_size > 0 and file_size > 0, (
                'both data size ({}) and file size ({}) must be positive @ index {}'.format(
                    data_size, file_size, i))
            part_name = decode_asciiz(part_name)
            chunk_name = decode_asciiz(chunk_name)
            parts.setdefault(
                hw_partition, collections.OrderedDict()).setdefault(
                    part_name, []).append(self.Chunk(
                        chunk_name, data_size, file.tell(), file_size,
                        part_hash, 0, 0, 0, 0, 0, False, False))
            if self._verify_data_hash:
                self._verify_data_hash.update(chunk_hdr_data)
                for chunk_data in iter_read(file, file_size, self.READ_CHUNK_SIZE):
                    self._verify_data_hash.update(chunk_data)
            else:
                file.seek(file_size, 1)
        assert verify_hdr_hash.digest() == self.chunk_hdrs_hash, (
            'chunk headers hash mismatch: expected {}, got {}'.format(
                binascii.hexlify(verify_hdr_hash.digest()),
                binascii.hexlify(self.chunk_hdrs_hash)))
        return parts

    def _parse_v1_part_headers(self, part_count, file):
        parts = collections.OrderedDict()
        verify_hdr_hash = hashlib.md5()
        part_start_sector = 0
        part_sector_count = 0
        for i in range(part_count):
            chunk_hdr_data = file.read(self.V1_PART_FMT.size)
            (magic, part_name, chunk_name,
                data_size, file_size, part_hash,
                start_sector, sector_count, hw_partition,
                part_crc, unique_part_id, is_sparse, is_ubi_image,
                maybe_pstart_sector, padding) = self.V1_PART_FMT.unpack(
                    chunk_hdr_data)
            verify_hdr_hash.update(chunk_hdr_data)
            assert magic == self.PART_MAGIC, (
                'invalid part magic {:x} @ index {}'.format(magic, i))
            assert all(b == 0 for b in padding), (
                'non zero bytes in part padding @ index {}'.format(i))
            assert data_size > 0 and file_size > 0, (
                'both data size ({}) and file size ({}) must be positive @ index {}'.format(
                    data_size, file_size, i))
            part_name = decode_asciiz(part_name)

            if hw_partition not in parts:
                part_start_sector = 0
                part_sector_count = 0

                if (maybe_pstart_sector > part_start_sector and
                        maybe_pstart_sector <= start_sector):
                    part_start_sector = maybe_pstart_sector
            elif part_name not in parts[hw_partition]:
                if maybe_pstart_sector == 0:
                    part_start_sector = start_sector
                else:
                    part_start_sector += part_sector_count

                    if (maybe_pstart_sector > part_start_sector and
                            maybe_pstart_sector <= start_sector):
                        part_start_sector = maybe_pstart_sector

                part_sector_count = 0

            assert maybe_pstart_sector == 0 or maybe_pstart_sector == part_start_sector, (
                'mismatch in part start sector @ index {} (expected {}, got {})'.format(
                    i, part_start_sector, maybe_pstart_sector))
            chunk_name = decode_asciiz(chunk_name)
            parts.setdefault(
                hw_partition, collections.OrderedDict()).setdefault(
                    part_name, []).append(self.Chunk(
                        chunk_name, data_size, file.tell(), file_size,
                        part_hash, part_crc, start_sector, sector_count,
                        part_start_sector, unique_part_id,
                        bool(is_sparse), bool(is_ubi_image)))

            part_sector_count = (start_sector - part_start_sector) + sector_count
            if self._verify_data_hash:
                self._verify_data_hash.update(chunk_hdr_data)
                for chunk_data in iter_read(file, file_size, self.READ_CHUNK_SIZE):
                    self._verify_data_hash.update(chunk_data)
            else:
                file.seek(file_size, 1)
        assert verify_hdr_hash.digest() == self.chunk_hdrs_hash, (
            'chunk headers hash mismatch: expected {}, got {}'.format(
                binascii.hexlify(verify_hdr_hash.digest()),
                binascii.hexlify(self.chunk_hdrs_hash)))
        return parts

def parse_kdz_header(f):
    def read_asciiz_data(offset, size):
        f.seek(offset)
        return decode_asciiz(f.read(size))

    hdr = KdzHeader(f)

    print('KDZ Header')
    print('==========')
    print('version = {}, magic = {:x}, size = {}'.format(hdr.version, hdr.magic, hdr.size))
    print('records = {}'.format(len(hdr.records)))
    for record in hdr.records:
        print('  {}'.format(record))
    print('tag = {}'.format(hdr.tag))
    print('extended_mem_id = {}'.format(hdr.extended_mem_id))
    print('  data = {}'.format(read_asciiz_data(hdr.extended_mem_id.offset, hdr.extended_mem_id.size)))
    print('additional_records_size = {}'.format(hdr.additional_records_size))
    print('  suffix_map = {}'.format(hdr.suffix_map))
    print('    data = {}'.format(read_asciiz_data(hdr.suffix_map.offset, hdr.suffix_map.size).split('\n')))
    print('  sku_map = {}'.format(hdr.sku_map))
    print('    data = {}'.format(read_asciiz_data(hdr.sku_map.offset, hdr.sku_map.size).split('\n')))
    print('  extended_sku_map = {}'.format(hdr.extended_sku_map))
    print('    data =')
    if hdr.extended_sku_map.size > 0:
        print('      {}'.format('\n      '.join(read_asciiz_data(
            hdr.extended_sku_map.offset, hdr.extended_sku_map.size).split('\n'))))
    print('ftm_model_name = {}'.format(hdr.ftm_model_name))
    print('')

    return hdr


def parse_secure_partition(f):
    try:
        sec_part = SecurePartition(f)
    except ValueError:
        print('No secure partition found')
    else:
        print('Secure Partition')
        print('================')
        print('magic = {:x}'.format(sec_part.magic))
        print('flags = {:x}'.format(sec_part.flags))
        print('signature = {}'.format(binascii.hexlify(sec_part.signature)))
        print('parts = {}'.format(sum(
            len(chunks) for p in sec_part.parts.values()
            for chunks in p.values())))
    print('')


def parse_dz_record(f, dz_record):
    f.seek(dz_record.offset)
    dz_hdr = DzHeader(f)

    print('DZ header')
    print('=========')
    print('magic = {:x}'.format(dz_hdr.magic))
    print('major = {}'.format(dz_hdr.major))
    print('minor = {}'.format(dz_hdr.minor))
    print('build date = {}'.format(dz_hdr.build_date))
    print('compression = {}'.format(dz_hdr.compression))
    print('secure_image_type = {}'.format(dz_hdr.secure_image_type))
    print('swfv = {}'.format(dz_hdr.swfv))
    print('build_type = {}'.format(dz_hdr.build_type))
    print('android_ver = {}'.format(dz_hdr.android_ver))
    print('memory_size = {}'.format(dz_hdr.memory_size))
    print('signed_security = {}'.format(dz_hdr.signed_security))
    print('anti_rollback_ver = {:x}'.format(dz_hdr.anti_rollback_ver))
    print('supported_mem = {}'.format(dz_hdr.supported_mem))
    print('target_product = {}'.format(dz_hdr.target_product))
    print('operator_code = {}'.format(dz_hdr.operator_code))
    print('multi_panel_mask = {}'.format(dz_hdr.multi_panel_mask))
    print('product_fuse_id = {}'.format(dz_hdr.product_fuse_id))
    print('is_factory_image = {}'.format(dz_hdr.is_factory_image))
    print('is_ufs = {}'.format(dz_hdr.is_ufs))
    print('chunk_hdrs_hash = {}'.format(
        binascii.hexlify(dz_hdr.chunk_hdrs_hash)))
    print('data_hash = {}'.format(binascii.hexlify(dz_hdr.data_hash)))
    print('header_crc = {:x}'.format(dz_hdr.header_crc))
    print('parts = {}'.format(sum(
        len(chunks) for p in dz_hdr.parts.values() for chunks in p.values())))
    print('')

    return dz_hdr


def extract_dz_parts(f, dz_hdr, out_path):
    if dz_hdr.compression == 'zlib':
        def decompressor():
            return zlib.decompressobj()
    elif dz_hdr.compression == 'zstd':
        def decompressor():
            # This unfortnately doesn't do any good because the zstd library
            # doesn't implement streaming decompression, so it'll load the
            # entire stream into memory *sigh*
            obj = zstandard.ZstdDecompressor()
            return obj.decompressobj()

    WRITE_FILL = b'\x00' * (4096 * 100)

    for hw_part, parts in dz_hdr.parts.items():
        print('Partition {}:'.format(hw_part))
        for pname, chunks in parts.items():
            out_file_name = os.path.join(out_path, '{}.{}.img'.format(hw_part, pname))
            print('  extracting part {}...'.format(pname))
            with open(out_file_name, 'wb') as out_f:
                start_offset = chunks[0].part_start_sector * 4096
                for i, chunk in enumerate(chunks):
                    print('    extracting chunk {} ({} bytes)...'.format(
                        chunk.name, max(
                            chunk.data_size, chunk.sector_count * 4096)))
                    expected_offset = chunk.start_sector * 4096
                    while start_offset < expected_offset:
                        write_len = min(
                            expected_offset - start_offset, len(WRITE_FILL))
                        out_f.write(WRITE_FILL[:write_len])
                        start_offset += write_len
                    f.seek(chunk.file_offset)
                    decomp = decompressor()
                    for chunk_data in iter_read(f, chunk.file_size, 1024*1024):
                        chunk_data = decomp.decompress(chunk_data)
                        out_f.write(chunk_data)
                        start_offset += len(chunk_data)
                    chunk_data = decomp.flush()
                    out_f.write(chunk_data)
                    start_offset += len(chunk_data)
                    # sec_chunk = sec_part.partitions[hw_part][
                    #     pname if pname != 'OP_S' else 'OP_a'][i]
                expected_offset = (chunks[-1].start_sector + chunks[-1].sector_count) * 4096
                while start_offset < expected_offset:
                    write_len = min(
                        expected_offset - start_offset, len(WRITE_FILL))
                    out_f.write(WRITE_FILL[:write_len])
                    start_offset += write_len
                print('  done. extracted size = {} bytes'.format(
                    start_offset - (chunks[0].start_sector * 4096)))
            print('')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('file', type=argparse.FileType('rb'))
    parser.add_argument('-e', '--extract-to')
    args = parser.parse_args()

    with args.file as in_file:
        kdz_header = parse_kdz_header(in_file)
        parse_secure_partition(in_file)
        try:
            dz_record = next(
                record for record in kdz_header.records
                if record.name.endswith('.dz'))
            dz_hdr = parse_dz_record(in_file, dz_record)
        except StopIteration:
            raise SystemExit('No DZ record in KDZ file')

        if args.extract_to:
            try:
                os.makedirs(args.extract_to)
            except (OSError, IOError) as e:
                if e.errno != errno.EEXIST:
                    raise

            extract_dz_parts(in_file, dz_hdr, args.extract_to)
        else:
            for hw_part, parts in dz_hdr.parts.items():
                print('Partition {}:'.format(hw_part))
                for pname, chunks in parts.items():
                    print('  {}'.format(pname))
                    for i, chunk in enumerate(chunks):
                        print('    {}. {} ({} bytes, sparse: {})'.format(
                            i, chunk.name, max(
                                chunk.data_size, chunk.sector_count * 4096),
                            chunk.is_sparse))
                    print('')


if __name__ == '__main__':
    main()