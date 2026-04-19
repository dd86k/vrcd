/// TCP stream abstraction (plain or TLS).
///
/// Provides a common send/receive interface so the rest of the server
/// can operate identically whether the transport is plain TCP or TLS
///
/// Depends on OpenSSL 3.0
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.stream;

import std.socket : Socket;
import std.string : toStringz, fromStringz;

import ddlogger;

/// Bidirectional byte-stream interface.
abstract class Stream
{
    /// Read up to buf.length bytes. Returns bytes read, or <=0 on close/error.
    abstract ptrdiff_t receive(void[] buf);

    /// Write data to the stream. Returns bytes sent, or <=0 on error.
    abstract ptrdiff_t send(const(void)[] data);

    /// Close the stream, releasing all resources.
    abstract void close();
}

/// Plain (unencrypted) TCP stream.
class PlainStream : Stream
{
    private Socket sock;

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

    override void close()
    {
        sock.close();
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
        SysLib ssl = sysLoad("libssl.so.3");
        if (ssl is null)
            ssl = sysLoad("libssl.so");

        SysLib crypto = sysLoad("libcrypto.so.3");
        if (crypto is null)
            crypto = sysLoad("libcrypto.so");
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

    T sym(T)(SysLib lib, const(char)* name)
    {
        void* s = sysSym(lib, name);
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

    override void close()
    {
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
    return cast(string) fromStringz(buf.ptr);
}
