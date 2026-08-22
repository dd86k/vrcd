/// TCP stream abstraction (plain or TLS).
///
/// Provides a common send/receive interface so the rest of the client
/// can operate identically whether the transport is plain TCP or TLS
///
/// Depends on OpenSSL 3.0
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.stream;

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

    /// Unblock a thread sitting in receive(), without releasing anything.
    ///
    /// This is the only method safe to call while another thread is inside
    /// receive() or send(): it shuts the socket down, so the blocked call
    /// returns, and touches no library state that call may be walking.
    /// close() must wait until that thread is gone.
    abstract void unblock();

    /// Close the stream, releasing all resources.
    /// Only call once no other thread can be inside receive() or send().
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

    override void unblock()
    {
        try sock.shutdown(SocketShutdown.BOTH); catch (Exception) {}
    }

    override void close()
    {
        unblock();
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

    if ((_TLS_client_method  = sym!FP_method    (ssl, "TLS_client_method")) is null) return false;
    if ((_SSL_CTX_new        = sym!FP_CTX_new   (ssl, "SSL_CTX_new"))       is null) return false;
    if ((_SSL_CTX_free       = sym!FP_CTX_free  (ssl, "SSL_CTX_free"))      is null) return false;
    if ((_SSL_CTX_set_verify = sym!FP_CTX_verify(ssl, "SSL_CTX_set_verify")) is null) return false;
    if ((_SSL_CTX_use_cert   = sym!FP_CTX_file  (ssl, "SSL_CTX_use_certificate_file")) is null) return false;
    if ((_SSL_CTX_use_key    = sym!FP_CTX_file  (ssl, "SSL_CTX_use_PrivateKey_file"))  is null) return false;
    if ((_SSL_CTX_check_key  = sym!FP_CTX_chk   (ssl, "SSL_CTX_check_private_key"))    is null) return false;
    if ((_SSL_CTX_load_verify = sym!FP_CTX_load (ssl, "SSL_CTX_load_verify_locations")) is null) return false;
    if ((_SSL_CTX_set_default_paths = sym!FP_CTX_paths(ssl, "SSL_CTX_set_default_verify_paths")) is null) return false;
    if ((_SSL_new            = sym!FP_SSL_new   (ssl, "SSL_new"))           is null) return false;
    if ((_SSL_free           = sym!FP_SSL_free  (ssl, "SSL_free"))          is null) return false;
    if ((_SSL_set_fd         = sym!FP_set_fd    (ssl, "SSL_set_fd"))        is null) return false;
    if ((_SSL_ctrl           = sym!FP_ctrl      (ssl, "SSL_ctrl"))          is null) return false;
    if ((_SSL_connect        = sym!FP_connect   (ssl, "SSL_connect"))       is null) return false;
    if ((_SSL_read           = sym!FP_read      (ssl, "SSL_read"))          is null) return false;
    if ((_SSL_write          = sym!FP_write     (ssl, "SSL_write"))         is null) return false;
    if ((_SSL_shutdown       = sym!FP_shutdown  (ssl, "SSL_shutdown"))      is null) return false;
    if ((_ERR_get_error      = sym!FP_ERR_get   (crypto, "ERR_get_error")) is null) return false;
    if ((_ERR_error_string_n = sym!FP_ERR_string(crypto, "ERR_error_string_n")) is null) return false;

    // Hostname checking is resolved separately: missing it costs the name
    // check, not TLS itself, so it must not fail the whole load.
    _SSL_get0_param       = cast(FP_get0_param) sysSym(ssl,    "SSL_get0_param");
    _X509_param_set1_host = cast(FP_param_host) sysSym(crypto, "X509_VERIFY_PARAM_set1_host");
    _X509_param_set1_ip   = cast(FP_param_ip)   sysSym(crypto, "X509_VERIFY_PARAM_set1_ip_asc");
    if (_SSL_get0_param is null || _X509_param_set1_host is null)
        logInfo("TLS: hostname verification unavailable (old OpenSSL)");

    _tlsLoaded = true;
    logInfo("TLS available (OpenSSL loaded)");
    return true;
}

/// Create a client-side TLS context.
/// If skipVerify is true, the server's certificate is not validated —
/// suitable for self-signed certificates on a local network.
/// When caCert is set, the server's certificate is verified against that
/// CA file instead of the system trust store — which is what a private CA
/// wants: trusting it system-wide would also trust it for every other
/// program on the machine.
/// When clientCert and clientKey are set, the client presents a
/// certificate to the server for mutual TLS authentication.
void* createClientTLSContext(bool skipVerify,
    string clientCert = null, string clientKey = null, string caCert = null)
{
    enum SSL_FILETYPE_PEM = 1;
    enum SSL_VERIFY_NONE = 0;
    enum SSL_VERIFY_PEER = 1;

    void* ctx = _SSL_CTX_new(_TLS_client_method());
    if (ctx is null)
        throw new Exception("SSL_CTX_new failed: " ~ tlsErrorString());

    int verifyMode = skipVerify ? SSL_VERIFY_NONE : SSL_VERIFY_PEER;
    _SSL_CTX_set_verify(ctx, verifyMode, null);

    // A fresh context has an empty trust store — OpenSSL reads the system
    // one only when asked. Without this, SSL_VERIFY_PEER rejects every
    // server, no matter who signed its certificate.
    if (skipVerify == false)
    {
        if (caCert.length > 0)
        {
            if (_SSL_CTX_load_verify(ctx, caCert.toStringz, null) != 1)
            {
                _SSL_CTX_free(ctx);
                throw new Exception("Failed to load CA certificate '" ~ caCert ~ "': " ~ tlsErrorString());
            }
        }
        else if (_SSL_CTX_set_default_paths(ctx) != 1)
        {
            _SSL_CTX_free(ctx);
            throw new Exception("Failed to load system CA certificates: " ~ tlsErrorString());
        }
    }

    // Load client certificate for mutual TLS.
    if (clientCert.length > 0 && clientKey.length > 0)
    {
        if (_SSL_CTX_use_cert(ctx, clientCert.toStringz, SSL_FILETYPE_PEM) != 1)
        {
            _SSL_CTX_free(ctx);
            throw new Exception("Failed to load client certificate '" ~ clientCert ~ "': " ~ tlsErrorString());
        }
        if (_SSL_CTX_use_key(ctx, clientKey.toStringz, SSL_FILETYPE_PEM) != 1)
        {
            _SSL_CTX_free(ctx);
            throw new Exception("Failed to load client key '" ~ clientKey ~ "': " ~ tlsErrorString());
        }
        if (_SSL_CTX_check_key(ctx) != 1)
        {
            _SSL_CTX_free(ctx);
            throw new Exception("Client certificate/key mismatch: " ~ tlsErrorString());
        }
    }

    return ctx;
}

/// Free a TLS context previously created by createClientTLSContext.
void freeTLSContext(void* ctx)
{
    if (ctx)
        _SSL_CTX_free(ctx);
}

/// TLS stream for a client-initiated connection (SSL_connect side).
/// The TCP socket must already be connected; this class performs the
/// TLS handshake synchronously in the constructor.
class TLSClientStream : Stream
{
    private Socket sock;
    private void* ssl;
    private bool socketDown;

    this(Socket s, void* ctx, string hostname, bool verifyHostname = false)
    {
        this.sock = s;
        ssl = _SSL_new(ctx);
        if (ssl is null)
            throw new Exception("SSL_new failed: " ~ tlsErrorString());

        // Check the certificate was issued for the host we asked for. The
        // chain check alone accepts anything the CA signed, including a
        // certificate it issued to a client.
        if (verifyHostname && _SSL_get0_param)
        {
            void* param = _SSL_get0_param(ssl);
            if (isIPAddress(hostname))
            {
                if (_X509_param_set1_ip)
                    _X509_param_set1_ip(param, hostname.toStringz);
            }
            else if (_X509_param_set1_host)
            {
                _X509_param_set1_host(param, hostname.toStringz, 0);
            }
        }

        // Set SNI hostname so the server can select the right certificate.
        // Skip for IP addresses — RFC 6066 requires a DNS name, and
        // OpenSSL 3.x rejects IP literals here.
        if (isIPAddress(hostname) == false)
        {
            enum SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
            _SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, cast(void*) hostname.toStringz);
        }
        _SSL_set_fd(ssl, cast(int) s.handle);

        if (_SSL_connect(ssl) != 1)
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

    /// Shut the TCP socket down so a blocked SSL_read returns.
    ///
    /// Deliberately touches no OpenSSL state: an SSL object may not be used
    /// from two threads at once, so freeing it here while the reader is
    /// inside SSL_read would pull the BIO out from under that call.
    override void unblock()
    {
        socketDown = true;
        try sock.shutdown(SocketShutdown.BOTH);
        catch (Exception) {}
    }

    override void close()
    {
        if (ssl)
        {
            // close_notify has nowhere to go once the socket is down, and
            // OpenSSL would only report the write failure back to us.
            if (socketDown == false)
                _SSL_shutdown(ssl);
            _SSL_free(ssl);
            ssl = null;
        }
        unblock();
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
    alias FP_CTX_file   = int function(void*, const(char)*, int);
    alias FP_CTX_load   = int function(void*, const(char)*, const(char)*);
    alias FP_CTX_paths  = int function(void*);
    alias FP_CTX_chk    = int function(void*);
    alias FP_get0_param = void* function(void*);
    alias FP_param_host = int function(void*, const(char)*, size_t);
    alias FP_param_ip   = int function(void*, const(char)*);
    alias FP_SSL_new    = void* function(void*);
    alias FP_SSL_free   = void function(void*);
    alias FP_set_fd     = int function(void*, int);
    alias FP_ctrl       = long function(void*, int, long, void*);
    alias FP_connect    = int function(void*);
    alias FP_read       = int function(void*, void*, int);
    alias FP_write      = int function(void*, const(void)*, int);
    alias FP_shutdown   = int function(void*);
    alias FP_ERR_get    = ulong function();
    alias FP_ERR_string = void function(ulong, char*, size_t);
}

private __gshared
{
    FP_method     _TLS_client_method;
    FP_CTX_new    _SSL_CTX_new;
    FP_CTX_free   _SSL_CTX_free;
    FP_CTX_verify _SSL_CTX_set_verify;
    FP_CTX_file   _SSL_CTX_use_cert;
    FP_CTX_file   _SSL_CTX_use_key;
    FP_CTX_load   _SSL_CTX_load_verify;
    FP_CTX_paths  _SSL_CTX_set_default_paths;
    FP_CTX_chk    _SSL_CTX_check_key;
    FP_get0_param _SSL_get0_param;
    FP_param_host _X509_param_set1_host;
    FP_param_ip   _X509_param_set1_ip;
    FP_SSL_new    _SSL_new;
    FP_SSL_free   _SSL_free;
    FP_set_fd     _SSL_set_fd;
    FP_ctrl       _SSL_ctrl;
    FP_connect    _SSL_connect;
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

/// True if the string looks like an IPv4 or IPv6 address rather than a hostname.
private bool isIPAddress(string s)
{
    import std.socket : parseAddress;
    try
    {
        parseAddress(s, 0);
        return true;
    }
    catch (Exception)
        return false;
}
