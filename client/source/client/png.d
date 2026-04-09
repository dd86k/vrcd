/// PNG metadata reader/writer
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
/// See_Also: https://www.w3.org/TR/png-3/
module client.png;

import std.stdio;
import core.bitop : bswap;
import std.digest.crc : crc32Of;
import std.file : read, write;
import std.array : Appender;

struct PNGMetadata
{
    string vrc;
    string vrcx;
}

/*
Textual information: iTXt, tEXt, zTXt (see 11.3.3 Textual information).
Miscellaneous information: bKGD, hIST, pHYs, sPLT, eXIf (see 11.3.4 Miscellaneous information).
*/
struct PNG
{
    this(string path)
    {
        open(path);
    }
    ~this()
    {
        close();
    }

    void open(string path)
    {
        file = File(path, "rb");

        // Reading magic for validation makes sense when opening
        ubyte[pngmagic.length] sigbuf;
        ubyte[] sig = file.rawRead(sigbuf);
        if (sig.length < pngmagic.length)
            throw new Exception("magic length");
        if (sig != pngmagic)
            throw new Exception("invalid magic");
    }

    void close()
    {
        if (file.isOpen()) // just in case if close() & ~this()
            file.close();
    }

    PNGMetadata metadata(bool vrc, bool vrcx)
    {
        PNGMetadata meta;
        bool gotvrc, gotvrcx;

        L: while (true)
        {
            PNGChunkHeader chunk = readchunk();

            ubyte[] chunkbuf;
            switch (chunk.ChunkType) {
            case "iTXt":
                // Size buffer to chunk's... assuming it's okay haha
                chunkbuf.length = chunk.Length;

                // Read data
                size_t chklen = file.rawRead(chunkbuf).length;
                if (chklen < chunkbuf.length)
                    throw new Exception("GRRRR missing chunk data");

                // Read CRC (which we skip, assuming it's fine)
                ubyte[4] crc32;
                size_t crclen = file.rawRead(crc32).length;
                if (crclen < crc32.length)
                    throw new Exception("GRRRR missing crc data");

                // VRC (XML) format
                // "XML:com.adobe.xmp\0\0\0\0\0" (22)
                static immutable string vrcmagic = "XML:com.adobe.xmp\0\0\0\0\0";
                if (vrc &&
                    chunk.Length > vrcmagic.length &&
                    chunkbuf[0..vrcmagic.length] == vrcmagic)
                {
                    meta.vrc = cast(string)chunkbuf[vrcmagic.length..$].idup;
                    gotvrc = true;
                    if (vrcx == false) // no VRCX and got VRC, get out
                        break L;
                    continue;
                }

                // VRCX (JSON) format
                // "Description\0\0\0\0\0" (16)
                static immutable string vrcxmagic = "Description\0\0\0\0\0";
                if (vrcx &&
                    chunk.Length > vrcxmagic.length &&
                    chunkbuf[0..vrcxmagic.length] == vrcxmagic)
                {
                    meta.vrcx = cast(string)chunkbuf[vrcxmagic.length..$].idup;
                    gotvrcx = true;
                    if (vrc == false) // no VRC and got VRCX, get out
                        break L;
                    continue;
                }
                break;
            case "IEND":
                break L;
            default:
                // Jump chunk + checksum
                file.seek(chunk.Length + 4, SEEK_CUR);
            }
        }

        return meta;
    }

    // strip iTXt chunks to new file
    void strip(string output)
    {
        // Open file and write magic, very simple, love PNG
        File outfile = File(output, "wb");
        outfile.rawWrite(pngmagic);

        import std.algorithm : min;
        enum BUFFERSIZE = 64 * 1024;
        ubyte[] buffer; buffer.length = BUFFERSIZE;
        while (file.eof == false)
        {
            PNGChunkHeader chunk = readchunk();

            // by chunk type...
            switch (chunk.ChunkType) {
            case "iTXt": // Skip
                // Jump chunk + checksum
                file.seek(chunk.Length + 4, SEEK_CUR);
                break;
            case "IEND": // Length=0,"IEND",CRC and exit to avoid exception
                // Write chunk header
                outfile.rawWrite((cast(ubyte*)&chunk)[0..PNGChunkHeader.sizeof]);
                // Write checksum
                ubyte[4] crc = void;
                file.rawRead(crc);
                outfile.rawWrite(crc);
                return;
            default:
                uint chksize = chunk.Length; // cheap hack, sorry

                // Write chunk header
                chunk.Length = bswap(chunk.Length);
                outfile.rawWrite((cast(ubyte*)&chunk)[0..PNGChunkHeader.sizeof]);

                // Write chunk data
                if (chunk.Length)
                {
                    uint read;
                    while (true)
                    {
                        uint amount = min(BUFFERSIZE, chksize - read);
                        file.rawRead(buffer[0..amount]);
                        outfile.rawWrite(buffer[0..amount]);
                        if (amount < BUFFERSIZE)
                            break;
                    }
                }

                // Write checksum
                ubyte[4] crc = void;
                file.rawRead(crc);
                outfile.rawWrite(crc);
            }
        }
    }

private
    File file;

    PNGChunkHeader readchunk()
    {
        PNGChunkHeader chunk = void;

        size_t len = file.rawRead((cast(ubyte*)&chunk)[0..PNGChunkHeader.sizeof]).length;
        if (len < PNGChunkHeader.sizeof)
            throw new Exception("Unexpected EOF");

        chunk.Length = bswap(chunk.Length);

        /*if (trace)
            stderr.writeln("chksize=", chksize, " chk=", dumb.hdr.ChunkType);*/

        return chunk;
    }
}

/// Write (or replace) a VRCX-style "Description" iTXt chunk in the given PNG.
/// The file is rewritten in place. Existing "Description" iTXt chunks are
/// dropped so the writer is idempotent.
void writeDescriptionChunk(string path, string jsonText)
{
    ubyte[] data = cast(ubyte[]) read(path);
    if (data.length < pngmagic.length || data[0 .. pngmagic.length] != pngmagic)
        throw new Exception("not a PNG");

    Appender!(ubyte[]) output;
    output.put(data[0 .. pngmagic.length]);

    static immutable string descKeyword = "Description";

    size_t offset = pngmagic.length;
    bool injected;

    while (offset + 12 <= data.length) // 8 header + 4 crc minimum
    {
        uint length =
            (cast(uint) data[offset    ]) << 24 |
            (cast(uint) data[offset + 1]) << 16 |
            (cast(uint) data[offset + 2]) <<  8 |
            (cast(uint) data[offset + 3]);
        char[4] chunkType = [
            cast(char) data[offset + 4],
            cast(char) data[offset + 5],
            cast(char) data[offset + 6],
            cast(char) data[offset + 7],
        ];
        size_t chunkEnd = offset + 8 + length + 4; // header + data + crc
        if (chunkEnd > data.length)
            throw new Exception("truncated PNG chunk");

        if (chunkType == "IEND")
        {
            // Inject our chunk before IEND.
            output.put(buildDescriptionChunk(jsonText));
            output.put(data[offset .. chunkEnd]);
            injected = true;
            break;
        }

        // Drop existing Description iTXt chunks for idempotence.
        bool dropChunk;
        if (chunkType == "iTXt" && length > descKeyword.length)
        {
            size_t dataStart = offset + 8;
            if (cast(string) data[dataStart .. dataStart + descKeyword.length] == descKeyword &&
                data[dataStart + descKeyword.length] == 0)
            {
                dropChunk = true;
            }
        }

        if (dropChunk == false)
            output.put(data[offset .. chunkEnd]);

        offset = chunkEnd;
    }

    if (injected == false)
        throw new Exception("PNG has no IEND chunk");

    write(path, output.data);
}

/// Build a complete iTXt chunk (length + type + data + CRC) for a VRCX-style
/// "Description" text chunk containing the given UTF-8 JSON text.
private ubyte[] buildDescriptionChunk(string jsonText)
{
    // iTXt data layout:
    //   keyword (1-79 bytes) + \0
    //   compression flag (1 byte)
    //   compression method (1 byte)
    //   language tag (0+ bytes) + \0
    //   translated keyword (0+ bytes) + \0
    //   text (UTF-8)
    Appender!(ubyte[]) data;
    data.put(cast(const(ubyte)[]) "Description");
    data.put(cast(ubyte) 0); // keyword null terminator
    data.put(cast(ubyte) 0); // compression flag: uncompressed
    data.put(cast(ubyte) 0); // compression method
    data.put(cast(ubyte) 0); // empty language tag
    data.put(cast(ubyte) 0); // empty translated keyword
    data.put(cast(const(ubyte)[]) jsonText);

    ubyte[] payload = data.data;
    uint length = cast(uint) payload.length;

    Appender!(ubyte[]) chunk;
    // Length (big-endian)
    chunk.put(cast(ubyte)((length >> 24) & 0xFF));
    chunk.put(cast(ubyte)((length >> 16) & 0xFF));
    chunk.put(cast(ubyte)((length >>  8) & 0xFF));
    chunk.put(cast(ubyte)( length        & 0xFF));
    // Chunk type
    chunk.put(cast(const(ubyte)[]) "iTXt");
    // Data
    chunk.put(payload);

    // CRC32 is computed over chunk type + data. crc32Of returns bytes in
    // little-endian order; PNG stores the value big-endian.
    ubyte[4] crc = crc32Of(chunk.data[4 .. $]);
    chunk.put(crc[3]);
    chunk.put(crc[2]);
    chunk.put(crc[1]);
    chunk.put(crc[0]);

    return chunk.data;
}

private:

immutable ubyte[] pngmagic = [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ];

struct PNGChunkHeader
{
    align(1):
    uint Length;
    char[4] ChunkType;
    // data ...
    // uint crc
}
