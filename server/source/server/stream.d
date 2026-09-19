/// Stream abstraction (plain TCP, TLS, or a stdio pipe).
///
/// Provides a common send/receive interface so the rest of the server
/// can operate identically whether the transport is plain TCP or TLS
///
/// Depends on OpenSSL 3.0
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.stream;

import core.atomic : atomicLoad, atomicStore;
import std.socket : Socket, SocketShutdown;
import std.string : toStringz, fromStringz;

import ddlogger;

/// Bidirectional byte-stream interface.
abstract class Stream
{
    /// Read up to buf.length bytes. Returns bytes read, or <=0 on close/error.
    abstract ptrdiff_t receive(void[] buf);

    /// Write data to the stream. Returns bytes sent, or <=0 on error.
    abstract ptrdiff_t send(const(void)[] data);

    /// Break the connection so a thread blocked in receive() returns, without
    /// releasing the descriptor.
    ///
    /// This is the only teardown call that is safe from another thread.
    /// close() releases the descriptor number, which the next accept() may
    /// hand straight to a new connection: a thread still parked in receive()
    /// would then be reading someone else's socket. shutdown() ends the
    /// connection while the number stays owned, so the reader wakes, returns
    /// 0, and closes the stream itself.
    abstract void shutdown();

    /// Close the stream, releasing all resources. Call only from the thread
    /// that owns the receive loop, and only once.
    abstract void close();
}

/// Plain (unencrypted) TCP stream.
class PlainStream : Stream
{
    private Socket sock;
    private shared bool closed;

    this(Socket s)
    {
        this.sock = s;
    }

    override ptrdiff_t receive(void[] buf)
    {
        return sock.receive(buf);
    }

    override ptrdiff_t send(const(void)[] data)
    {
        return sock.send(data);
    }

    override void shutdown()
    {
        // Never shut down a descriptor we have already released: the number
        // may belong to another connection by now.
        if (atomicLoad(closed))
            return;
        sock.shutdown(SocketShutdown.BOTH);
    }

    override void close()
    {
        if (atomicLoad(closed))
            return;
        atomicStore(closed, true);
        sock.close();
    }
}

version (Posix)
{
    private import core.sys.posix.unistd : sysRead = read, sysWrite = write,
        sysDup = dup, sysDup2 = dup2, sysClose = close;
}
else version (Windows)
{
    // The CRT's descriptor layer rather than the Win32 handle one: a child's
    // redirected stdio arrives as descriptors 0/1/2 either way, and going
    // through _dup/_read keeps this module identical on both platforms.
    private extern (C) nothrow @nogc
    {
        int _read(int, void*, uint);
        int _write(int, const(void)*, uint);
        int _dup(int);
        int _dup2(int, int);
        int _close(int);
    }
    private alias sysRead  = _read;
    private alias sysWrite = _write;
    private alias sysDup   = _dup;
    private alias sysDup2  = _dup2;
    private alias sysClose = _close;
}

/// Pipe stream over a pair of file descriptors.
///
/// The transport an embedded server speaks: the front-end launches it as a
/// child and talks JSON-L over its stdin/stdout, so there is no listener, no
/// port to pick and no secret to agree on -- holding the pipe *is* the
/// authorization, and the pipe closing is how either side learns the other
/// is gone.
class PipeStream : Stream
{
    private int readFd = -1;
    private int writeFd = -1;
    private shared bool closed;

    this(int readFd, int writeFd)
    {
        this.readFd = readFd;
        this.writeFd = writeFd;
    }

    /// Take over the process's stdin/stdout, and point descriptor 1 at stderr.
    ///
    /// Stdout is the wire from here on, so a stray `writeln` anywhere in the
    /// server would corrupt a JSON line rather than fail loudly. Only the
    /// duplicate this returns still reaches the pipe; the descriptor the rest
    /// of the process writes through lands in the log beside every other
    /// diagnostic.
    static PipeStream fromStdio()
    {
        int out_ = sysDup(1);
        if (out_ < 0)
            throw new Exception("Could not duplicate stdout for the pipe");
        sysDup2(2, 1);
        return new PipeStream(0, out_);
    }

    override ptrdiff_t receive(void[] buf)
    {
        if (atomicLoad(closed))
            return 0;
        return sysRead(readFd, buf.ptr, cast(uint) buf.length);
    }

    override ptrdiff_t send(const(void)[] data)
    {
        if (atomicLoad(closed))
            return -1;
        return sysWrite(writeFd, data.ptr, cast(uint) data.length);
    }

    /// Close the write end so the peer reads EOF and hangs up, which is what
    /// wakes a thread blocked in receive().
    ///
    /// Closing the read end directly would be the socket shutdown's
    /// equivalent, but a descriptor number released while a reader is still
    /// parked on it is the one hazard worth avoiding: the next open() gets
    /// that number. Going through the peer costs a round trip and cannot
    /// read somebody else's pipe.
    override void shutdown()
    {
        if (atomicLoad(closed))
            return;
        if (writeFd >= 0)
        {
            sysClose(writeFd);
            writeFd = -1;
        }
    }

    /// Release the write end and stop reading.
    ///
    /// The read end is descriptor 0, which the C runtime's `stdin` also
    /// refers to and closes at exit; freeing the number here would let an
    /// unrelated open claim it first and be closed on somebody else's
    /// behalf. Marking the stream closed is enough, since an embedded
    /// server whose pipe has gone is on its way out anyway.
    override void close()
    {
        if (atomicLoad(closed))
            return;
        atomicStore(closed, true);
        if (writeFd >= 0)
        {
            sysClose(writeFd);
            writeFd = -1;
        }
        readFd = -1;
    }
}

//
// Dynamic OpenSSL loading
//

version (Posix)
{
    private import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;
    private alias SysLib = void*;
    private SysLib sysLoad(const(char)* name) { return dlopen(name, RTLD_NOW); }
    private void* sysSym(SysLib lib, const(char)* name) { return dlsym(lib, name); }
}
else version (Windows)
{
    private extern (Windows) @nogc nothrow
    {
        void* LoadLibraryA(const(char)* lpFileName);
        void* GetProcAddress(void* hModule, const(char)* lpProcName);
    }
    private alias SysLib = void*;
    private SysLib sysLoad(const(char)* name) { return LoadLibraryA(name); }
    private void* sysSym(SysLib lib, const(char)* name) { return GetProcAddress(lib, name); }
}

/// Whether the OpenSSL runtime library was successfully loaded.
bool tlsAvailable()
{
    return _tlsLoaded;
}

/// Attempt to dynamically load OpenSSL. Safe to call multiple times;
/// returns true if TLS functions are ready for use.
bool loadTLS()
{
    if (_tlsLoaded)
        return true;
    if (_tlsAttempted)
        return false;
    _tlsAttempted = true;

    version (Posix)
    {
        // NOTE: libssl3.so is part of NSS and not OpenSSL
        SysLib ssl = sysLoad("libssl.so.3");
        if (ssl is null)
            ssl = sysLoad("libssl.so"); // fallback

        SysLib crypto = sysLoad("libcrypto.so.3");
        if (crypto is null)
            crypto = sysLoad("libcrypto.so"); // fallback
    }
    else version (Windows)
    {
        SysLib ssl = sysLoad("libssl-3-x64.dll");
        if (ssl is null)
            ssl = sysLoad("libssl-3.dll");

        SysLib crypto = sysLoad("libcrypto-3-x64.dll");
        if (crypto is null)
            crypto = sysLoad("libcrypto-3.dll");
    }
    else
    {
        logInfo("TLS unavailable: unsupported platform");
        return false;
    }

    if (ssl is null)
    {
        logInfo("TLS unavailable: could not load libssl");
        return false;
    }
    if (crypto is null)
    {
        logInfo("TLS unavailable: could not load libcrypto");
        return false;
    }

    T sym(T)(SysLib lib, string name)
    {
        void* s = sysSym(lib, name.ptr);
        if (s is null)
        {
            logInfo("TLS unavailable: missing symbol %s", name);
            return null;
        }
        return cast(T) s;
    }

    if ((_TLS_server_method    = sym!FP_method  (ssl, "TLS_server_method")) is null) return false;
    if ((_SSL_CTX_new          = sym!FP_CTX_new (ssl, "SSL_CTX_new"))       is null) return false;
    if ((_SSL_CTX_free         = sym!FP_CTX_free(ssl, "SSL_CTX_free"))      is null) return false;
    if ((_SSL_CTX_set_verify   = sym!FP_CTX_verify(ssl, "SSL_CTX_set_verify")) is null) return false;
    if ((_SSL_CTX_load_verify  = sym!FP_CTX_load(ssl, "SSL_CTX_load_verify_locations")) is null) return false;
    if ((_SSL_CTX_use_cert     = sym!FP_CTX_file(ssl, "SSL_CTX_use_certificate_file")) is null) return false;
    if ((_SSL_CTX_use_key      = sym!FP_CTX_file(ssl, "SSL_CTX_use_PrivateKey_file"))  is null) return false;
    if ((_SSL_CTX_check_key    = sym!FP_CTX_chk (ssl, "SSL_CTX_check_private_key"))    is null) return false;
    if ((_SSL_new              = sym!FP_SSL_new (ssl, "SSL_new"))           is null) return false;
    if ((_SSL_free             = sym!FP_SSL_free(ssl, "SSL_free"))          is null) return false;
    if ((_SSL_set_fd           = sym!FP_set_fd  (ssl, "SSL_set_fd"))        is null) return false;
    if ((_SSL_accept           = sym!FP_accept  (ssl, "SSL_accept"))        is null) return false;
    if ((_SSL_read             = sym!FP_read    (ssl, "SSL_read"))          is null) return false;
    if ((_SSL_write            = sym!FP_write   (ssl, "SSL_write"))         is null) return false;
    if ((_SSL_shutdown         = sym!FP_shutdown(ssl, "SSL_shutdown"))      is null) return false;
    if ((_ERR_get_error        = sym!FP_ERR_get   (crypto, "ERR_get_error")) is null) return false;
    if ((_ERR_error_string_n   = sym!FP_ERR_string(crypto, "ERR_error_string_n")) is null) return false;

    _tlsLoaded = true;
    logInfo("TLS available (OpenSSL loaded)");
    return true;
}

/// Create a server-side TLS context from PEM certificate and key files.
/// When caPath is set and verifyClient is true, the server requires
/// clients to present a certificate signed by that CA (mutual TLS).
/// Throws on any failure.
void* createServerTLSContext(string certPath, string keyPath,
    string caPath = null, bool verifyClient = false)
{
    enum SSL_FILETYPE_PEM = 1;
    enum SSL_VERIFY_NONE = 0;
    enum SSL_VERIFY_PEER = 0x01;
    enum SSL_VERIFY_FAIL_IF_NO_PEER_CERT = 0x02;

    void* ctx = _SSL_CTX_new(_TLS_server_method());
    if (ctx is null)
        throw new Exception("SSL_CTX_new failed: " ~ tlsErrorString());

    if (_SSL_CTX_use_cert(ctx, certPath.toStringz, SSL_FILETYPE_PEM) != 1)
    {
        _SSL_CTX_free(ctx);
        throw new Exception("Failed to load certificate '" ~ certPath ~ "': " ~ tlsErrorString());
    }

    if (_SSL_CTX_use_key(ctx, keyPath.toStringz, SSL_FILETYPE_PEM) != 1)
    {
        _SSL_CTX_free(ctx);
        throw new Exception("Failed to load private key '" ~ keyPath ~ "': " ~ tlsErrorString());
    }

    if (_SSL_CTX_check_key(ctx) != 1)
    {
        _SSL_CTX_free(ctx);
        throw new Exception("Certificate/key mismatch: " ~ tlsErrorString());
    }

    // Mutual TLS: require and verify a client certificate.
    if (caPath.length > 0 && verifyClient)
    {
        if (_SSL_CTX_load_verify(ctx, caPath.toStringz, null) != 1)
        {
            _SSL_CTX_free(ctx);
            throw new Exception("Failed to load CA certificate '" ~ caPath ~ "': " ~ tlsErrorString());
        }
        _SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, null);
    }

    return ctx;
}

/// Free a TLS context previously created by createServerTLSContext.
void freeTLSContext(void* ctx)
{
    if (ctx)
        _SSL_CTX_free(ctx);
}

/// TLS stream for a server-accepted connection (SSL_accept side).
/// The TCP socket must already be connected; this class performs the
/// TLS handshake synchronously in the constructor.
class TLSServerStream : Stream
{
    private Socket sock;
    private void* ssl;
    private shared bool closed;

    this(Socket s, void* ctx)
    {
        this.sock = s;
        ssl = _SSL_new(ctx);
        if (ssl is null)
            throw new Exception("SSL_new failed: " ~ tlsErrorString());

        _SSL_set_fd(ssl, cast(int) s.handle);

        if (_SSL_accept(ssl) != 1)
        {
            string err = tlsErrorString();
            _SSL_free(ssl);
            ssl = null;
            throw new Exception("TLS handshake failed: " ~ err);
        }
    }

    override ptrdiff_t receive(void[] buf)
    {
        return _SSL_read(ssl, buf.ptr, cast(int) buf.length);
    }

    override ptrdiff_t send(const(void)[] data)
    {
        return _SSL_write(ssl, data.ptr, cast(int) data.length);
    }

    override void shutdown()
    {
        // Straight to the socket: SSL_shutdown() writes a close_notify, which
        // would race the reader thread still inside SSL_read().
        if (atomicLoad(closed))
            return;
        sock.shutdown(SocketShutdown.BOTH);
    }

    override void close()
    {
        if (atomicLoad(closed))
            return;
        atomicStore(closed, true);

        if (ssl)
        {
            _SSL_shutdown(ssl);
            _SSL_free(ssl);
            ssl = null;
        }
        sock.close();
    }
}

//
// Private: function pointers and state
//

private __gshared bool _tlsLoaded;
private __gshared bool _tlsAttempted;

private extern (C) @nogc nothrow
{
    alias FP_method     = void* function();
    alias FP_CTX_new    = void* function(void*);
    alias FP_CTX_free   = void function(void*);
    alias FP_CTX_verify = void function(void*, int, void*);
    alias FP_CTX_load   = int function(void*, const(char)*, const(char)*);
    alias FP_CTX_file   = int function(void*, const(char)*, int);
    alias FP_CTX_chk    = int function(void*);
    alias FP_SSL_new    = void* function(void*);
    alias FP_SSL_free   = void function(void*);
    alias FP_set_fd     = int function(void*, int);
    alias FP_accept     = int function(void*);
    alias FP_read       = int function(void*, void*, int);
    alias FP_write      = int function(void*, const(void)*, int);
    alias FP_shutdown   = int function(void*);
    alias FP_ERR_get    = ulong function();
    alias FP_ERR_string = void function(ulong, char*, size_t);
}

private __gshared
{
    FP_method     _TLS_server_method;
    FP_CTX_new    _SSL_CTX_new;
    FP_CTX_free   _SSL_CTX_free;
    FP_CTX_verify _SSL_CTX_set_verify;
    FP_CTX_load   _SSL_CTX_load_verify;
    FP_CTX_file   _SSL_CTX_use_cert;
    FP_CTX_file   _SSL_CTX_use_key;
    FP_CTX_chk    _SSL_CTX_check_key;
    FP_SSL_new    _SSL_new;
    FP_SSL_free   _SSL_free;
    FP_set_fd     _SSL_set_fd;
    FP_accept     _SSL_accept;
    FP_read       _SSL_read;
    FP_write      _SSL_write;
    FP_shutdown   _SSL_shutdown;
    FP_ERR_get    _ERR_get_error;
    FP_ERR_string _ERR_error_string_n;
}

/// Format the most recent OpenSSL error as a human-readable string.
private string tlsErrorString()
{
    char[256] buf;
    _ERR_error_string_n(_ERR_get_error(), buf.ptr, buf.length);
    return fromStringz(buf.ptr).idup;
}
