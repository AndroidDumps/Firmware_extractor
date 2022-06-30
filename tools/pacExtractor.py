#!/usr/bin/env python3

# This program is used for unpacking .pac file of Spreadtrum Firmware used in SPD Flash Tool for flashing.
# requires Python 3.7+
#
# Created : 31st January 2022
# Author  : HemanthJabalpuri
#
# This file has been put into the public domain.
# You can do whatever you want with this file.

import argparse, os, struct, sys


# 2124 bytes = (22*2)+4+4+(256*2)+(256*2)+4+4+4+4+4+4+4+(100*2)+4+4+4+(800*1)+4+2+2
PAC_HEADER_FMT = '44s I I 512s 512s I I I I I I I 200s I I I 800s I H H'

# 2580 bytes = 4+(256*2)+(256*2)+(252*2)+4+4+4+4+4+4+4+4+(5*4)+(996*1)
FILE_HEADER_FMT = 'I 512s 512s 504s I I I I I I I I 5I 996s'

PAC_MAGIC = '0xfffafffa'
fiveSpaces = ' ' * 5

PAC_HEADER = {
    'szVersion': '',            # packet struct version
    'dwHiSize': 0,              # the whole packet high size
    'dwLoSize': 0,              # the whole packet low size
    'productName': '',          # product name
    'firmwareName': '',         # product version
    'partitionCount': 0,        # the number of files that will be downloaded, the file may be an operation
    'partitionsListStart': 0,   # the offset from the packet file header to the array of PartitionHeaders start
    'dwMode': 0,
    'dwFlashType': 0,
    'dwNandStrategy': 0,
    'dwIsNvBackup': 0,
    'dwNandPageType': 0,
    'szPrdAlias': '',           # product alias
    'dwOmaDmProductFlag': 0,
    'dwIsOmaDM': 0,
    'dwIsPreload': 0,
    'dwReserved': 0,
    'dwMagic': 0,
    'wCRC1': 0,
    'wCRC2': 0
}

FILE_HEADER = {
    'length': 0,                # size of this struct itself
    'partitionName': '',        # file ID,such as FDL,Fdl2,NV and etc.
    'fileName': '',             # file name in the packet bin file. It only stores file name
    'szFileName': '',           # Reserved now
    'hiPartitionSize': 0,       # high file size
    'hiDataOffset': 0,          # high data offset
    'loPartitionSize': 0,       # low file size
    'nFileFlag': 0,             # if "0", means that it need not a file, and
                                # it is only an operation or a list of operations, such as file ID is "FLASH"
                                # if "1", means that it need a file
    'nCheckFlag': 0,            # if "1", this file must be downloaded
                                # if "0", this file can not be downloaded
    'loDataOffset': 0,          # the low offset from the packet file header to this file data
    'dwCanOmitFlag': 0,         # if "1", this file can not be downloaded and not check it as "All files"
                                # in download and spupgrade tool.
    'dwAddrNum': 0,
    'dwAddr': 0,
    'dwReserved': 0             # Reserved for future, not used now
}


def abort(msg):
    sys.exit(msg)


def getString(name):
    return name.decode('utf-16le').rstrip('\x00')


def printP(name, value):
    print(f'{name.ljust(13)} = {value}')


def printPacHeader(ph):
    printP('Version', ph['szVersion'])
    if ph['dwHiSize'] == 0x00:
        printP('Size', ph['dwLoSize'])
    else:
        printP('HiSize', ph['dwHiSize'])
        printP('LoSize', ph['dwLoSize'])
        printP('Size', ph['dwHiSize'] * 0x100000000 + ph['dwLoSize'])
    printP('PrdName', ph['productName'])
    printP('FirmwareName', ph['firmwareName'])
    printP('FileCount', ph['partitionCount'])
    printP('FileOffset', ph['partitionsListStart'])
    printP('Mode', ph['dwMode'])
    printP('FlashType', ph['dwFlashType'])
    printP('NandStrategy', ph['dwNandStrategy'])
    printP('IsNvBackup', ph['dwIsNvBackup'])
    printP('NandPageType', ph['dwNandPageType'])
    printP('PrdAlias', ph['szPrdAlias'])
    printP('OmaDmPrdFlag', ph['dwOmaDmProductFlag'])
    printP('IsOmaDM', ph['dwIsOmaDM'])
    printP('IsPreload', ph['dwIsPreload'])
    printP('Magic', hex(ph['dwMagic']))
    printP('CRC1', ph['wCRC1'])
    printP('CRC2', ph['wCRC2'])
    print('\n')


def parsePacHeader(f, pacfile, debug):
    pacHeader = PAC_HEADER.copy()
    pacHeaderBin = struct.unpack(PAC_HEADER_FMT, f.read(struct.calcsize(PAC_HEADER_FMT)))

    for i, (k, v) in enumerate(pacHeader.items()):
        if str(v) == '0':
            pacHeader[k] = pacHeaderBin[i]
        else:
            pacHeader[k] = getString(pacHeaderBin[i])

    if debug:
        printPacHeader(pacHeader)

    if pacHeader['szVersion'] != 'BP_R1.0.0' and pacHeader['szVersion'] != 'BP_R2.0.1':
        abort('Unsupported PAC version')

    dwSize = pacHeader['dwHiSize'] * 0x100000000 + pacHeader['dwLoSize']
    if dwSize != os.stat(pacfile).st_size:
        abort("Bin packet's size is not correct")

    return pacHeader


def verifyCRC16(f, ph, debug):
    import crc16
    if hex(ph['dwMagic']) == PAC_MAGIC:
        print('Checking CRC Part 1')
        f.seek(0)
        crcbuf = f.read(struct.calcsize(PAC_HEADER_FMT) - 4)
        crc1val = crc16.crc16(crcbuf)
        if crc1val != ph['wCRC1']:
            if debug:
                print(f'Computed CRC1 = {crc1val}, CRC1 in PAC = {ph["wCRC1"]}')
            abort('CRC Check failed for CRC1\n')

    print('Checking CRC Part 2')
    f.seek(struct.calcsize(PAC_HEADER_FMT))
    bufsize = 64 * 1024
    tempsize = (ph['dwHiSize'] * 0x100000000 + ph['dwLoSize']) - struct.calcsize(PAC_HEADER_FMT)
    tsize = tempsize
    crc2val = 0
    while tempsize > 0:
        if tempsize < bufsize:
            bufsize = tempsize
        crcbuf = f.read(bufsize)
        tempsize -= bufsize
        crc2val = crc16.crc16(crcbuf, crc2val)
        print(f'\r{int(100 - ((100 * tempsize) / tsize))}%', end='')
    print(f'\r{fiveSpaces}')
    if crc2val != ph['wCRC2']:
        if debug:
            print(f'Computed CRC2 = {crc2val}, CRC2 in PAC = {ph["wCRC2"]}\n')
        abort('CRC Check failed for CRC2')


def printFileHeader(fh):
    printP('Size', fh['length'])
    printP('FileID', fh['partitionName'])
    printP('FileName', fh['fileName'])
    if fh['hiPartitionSize'] == 0x00:
        printP('FileSize', fh['loPartitionSize'])
    else:
        printP('HiFileSize', fh['hiPartitionSize'])
        printP('LoFileSize', fh['loPartitionSize'])
        printP('FileSize', fh['hiPartitionSize'] * 0x100000000 + fh['loPartitionSize'])
    printP('FileFlag', fh['nFileFlag'])
    printP('CheckFlag', fh['nCheckFlag'])
    if fh['hiDataOffset'] == 0x00:
        printP('DataOffset', fh['loDataOffset'])
    else:
        printP('HiDataOffset', fh['hiDataOffset'])
        printP('LoDataOffset', fh['loDataOffset'])
        printP('DataOffset', fh['hiDataOffset'] * 0x100000000 + fh['loDataOffset'])
    printP('CanOmitFlag', fh['dwCanOmitFlag'])
    print()


def parseFiles(f, fileHeaders, debug):
    fileHeader = FILE_HEADER.copy()
    fileHeaderBin = struct.unpack(FILE_HEADER_FMT, f.read(struct.calcsize(FILE_HEADER_FMT)))

    for i, (k, v) in enumerate(fileHeader.items()):
        if str(v) == '0':
            fileHeader[k] = fileHeaderBin[i]
        else:
            fileHeader[k] = getString(fileHeaderBin[i])

    if fileHeader['length'] != struct.calcsize(FILE_HEADER_FMT):
        abort('Unknown Partition Header format found')

    if debug:
        printFileHeader(fileHeader)

    fileHeaders.append(fileHeader)


def extractFile(f, fh, outdir):
    tempsize = fh['hiPartitionSize'] * 0x100000000 + fh['loPartitionSize']
    if tempsize == 0:
        return
    print(f'{fiveSpaces}{fh["fileName"]}', end='')

    f.seek(fh['hiDataOffset'] * 0x100000000 + fh['loDataOffset'])
    size = 4096
    tsize = tempsize
    with open(os.path.join(outdir, fh['fileName']), 'wb') as ofile:
        while tempsize > 0:
            if tempsize < size:
                size = tempsize
            dat = f.read(size)
            tempsize -= size
            ofile.write(dat)
            print(f'\r{int(100 - ((100 * tempsize) / tsize))}%', end='')

    print(f'\r{fh["fileName"]}{fiveSpaces}')


# main('path/to/pacfile')
def main(pacfile, outdir=None, debug=False, checkCRC16=False):
    if os.stat(pacfile).st_size < struct.calcsize(PAC_HEADER_FMT):
        abort(f'{pacfile} is not a PAC firmware.')
    if outdir is None:  # use 'outdir' as default output directory if None specified
        outdir = os.path.join(os.getcwd(), 'outdir')
    if os.path.isfile(outdir):
        abort(f'file with name "{outdir}" exists')

    with open(pacfile, 'rb') as f:
        # Unpack pac Header
        pacHeader = parsePacHeader(f, pacfile, debug)

        # Verify crc16
        if checkCRC16:
            verifyCRC16(f, pacHeader, debug)

        # Unpack partition Headers
        fileHeaders = []
        f.seek(pacHeader['partitionsListStart'])
        for i in range(pacHeader['partitionCount']):
            parseFiles(f, fileHeaders, debug)

        # Extract partitions using partition headers
        print(f'\nExtracting to {outdir}\n')
        os.makedirs(outdir, exist_ok=True)
        for i in range(pacHeader['partitionCount']):
            extractFile(f, fileHeaders[i], outdir)

    print('\nDone...')


if __name__ == '__main__':
    if not sys.version_info >= (3, 7):
        # Python 3.7 for keeping inserted order in dictionary
        # Python 3.6 for f-strings
        abort('Requires Python 3.7+')

    parser = argparse.ArgumentParser()
    parser.add_argument('pacfile', help='Spreadtrum .pac file')
    parser.add_argument('outdir', nargs='?', help='output directory to extract files')
    parser.add_argument('-d', dest='debug', action='store_true', help='enable debug output')
    parser.add_argument('-c', dest='checkCRC16', action='store_true', help='compute and verify CRC16')
    args = parser.parse_args()

    main(args.pacfile, args.outdir, args.debug, args.checkCRC16)
