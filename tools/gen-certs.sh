#!/bin/sh
#
# Generate a private CA plus server and client certificates for vrcd's
# mutual TLS (mTLS) transport.
#
# The CA is reused when it already exists, so adding a client later is
# just another run with -c: existing certificates stay valid.
#
# Requires: openssl 1.1.1 or later.

set -e

OUTDIR=certs
DAYS=3650
ALGO=ec
FORCE=0
HOSTS=
CLIENTS=
CA_CN=vrcd-ca
SERVER_CN=vrcd-server

usage()
{
    cat <<EOF
Usage: $0 [options]

Options:
  -o DIR    Output directory (default: $OUTDIR)
  -H HOST   Hostname or IP the server is reached at; repeatable.
            Default: vrcd-server, localhost, 127.0.0.1, ::1
  -c NAME   Client certificate to issue; repeatable (default: client)
  -d DAYS   Validity in days (default: $DAYS)
  -a ALGO   Key algorithm: rsa (4096) or ec (P-256) (default: $ALGO)
  -f        Overwrite existing files, including the CA
  -h        This help

Examples:
  $0                                  # CA + server + one client
  $0 -H vrcd.lan -H 192.168.1.20      # server reachable under both
  $0 -c desktop -c quest              # two client certificates
  $0 -c laptop                        # add a client to an existing CA
EOF
}

while getopts "o:H:c:d:a:fh" opt; do
    case "$opt" in
    o) OUTDIR=$OPTARG ;;
    H) HOSTS="$HOSTS $OPTARG" ;;
    c) CLIENTS="$CLIENTS $OPTARG" ;;
    d) DAYS=$OPTARG ;;
    a) ALGO=$OPTARG ;;
    f) FORCE=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
    esac
done

case "$ALGO" in
rsa|ec) ;;
*) echo "error: unknown algorithm '$ALGO' (expected rsa or ec)" >&2; exit 2 ;;
esac

command -v openssl >/dev/null 2>&1 || {
    echo "error: openssl not found in PATH" >&2
    exit 1
}

[ -n "$HOSTS" ]   || HOSTS="vrcd-server localhost 127.0.0.1 ::1"
[ -n "$CLIENTS" ] || CLIENTS="client"

# Repeated options accumulate a leading space; drop it so the values read
# properly where they are echoed back.
HOSTS=${HOSTS# }
CLIENTS=${CLIENTS# }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

mkdir -p "$OUTDIR"

# Keys are written with the umask in effect, before any chmod can run.
umask 077

genkey()
{
    # $1: output path
    if [ "$ALGO" = ec ]; then
        openssl genpkey -algorithm EC \
            -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null
    else
        openssl genpkey -algorithm RSA \
            -pkeyopt rsa_keygen_bits:4096 -out "$1" 2>/dev/null
    fi
}

# An IP goes in the SAN as IP:, anything else as DNS:. A name that never
# resolves is harmless, but an address listed as DNS: matches nothing.
is_ip()
{
    case "$1" in
    *:*) return 0 ;;                       # IPv6
    *[!0-9.]*) return 1 ;;
    *.*.*.*) return 0 ;;
    *) return 1 ;;
    esac
}

exists()
{
    [ -f "$1" ] && [ "$FORCE" -eq 0 ]
}

# --- CA -------------------------------------------------------------

CA_KEY=$OUTDIR/ca.key
CA_CRT=$OUTDIR/ca.crt

if exists "$CA_CRT" && [ -f "$CA_KEY" ]; then
    echo "ca:     reusing $CA_CRT"
else
    genkey "$CA_KEY"
    openssl req -x509 -new -key "$CA_KEY" -sha256 -days "$DAYS" \
        -subj "/CN=$CA_CN" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$CA_CRT"
    echo "ca:     $CA_CRT"
fi

# --- server ---------------------------------------------------------

SRV_KEY=$OUTDIR/server.key
SRV_CRT=$OUTDIR/server.crt

if exists "$SRV_CRT"; then
    echo "server: reusing $SRV_CRT"
else
    {
        echo "basicConstraints=critical,CA:FALSE"
        echo "keyUsage=critical,digitalSignature,keyEncipherment"
        echo "extendedKeyUsage=serverAuth"
        echo "subjectKeyIdentifier=hash"
        echo "authorityKeyIdentifier=keyid,issuer"
        echo "subjectAltName=@alt"
        echo "[alt]"
        dnsn=0
        ipn=0
        for h in $HOSTS; do
            if is_ip "$h"; then
                ipn=$((ipn + 1))
                echo "IP.$ipn=$h"
            else
                dnsn=$((dnsn + 1))
                echo "DNS.$dnsn=$h"
            fi
        done
    } > "$TMPDIR/server.ext"

    genkey "$SRV_KEY"
    openssl req -new -key "$SRV_KEY" -subj "/CN=$SERVER_CN" \
        -out "$TMPDIR/server.csr"
    openssl x509 -req -in "$TMPDIR/server.csr" -sha256 -days "$DAYS" \
        -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
        -extfile "$TMPDIR/server.ext" -out "$SRV_CRT" 2>/dev/null
    echo "server: $SRV_CRT (SAN: $HOSTS)"
fi

# --- clients --------------------------------------------------------

{
    echo "basicConstraints=critical,CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=clientAuth"
    echo "subjectKeyIdentifier=hash"
    echo "authorityKeyIdentifier=keyid,issuer"
} > "$TMPDIR/client.ext"

for name in $CLIENTS; do
    key=$OUTDIR/$name.key
    crt=$OUTDIR/$name.crt

    if exists "$crt"; then
        echo "client: reusing $crt"
        continue
    fi

    genkey "$key"
    openssl req -new -key "$key" -subj "/CN=$name" -out "$TMPDIR/$name.csr"
    openssl x509 -req -in "$TMPDIR/$name.csr" -sha256 -days "$DAYS" \
        -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
        -extfile "$TMPDIR/client.ext" -out "$crt" 2>/dev/null
    echo "client: $crt"
done

chmod 600 "$OUTDIR"/*.key
chmod 644 "$OUTDIR"/*.crt

# --- verify ---------------------------------------------------------

for crt in "$SRV_CRT" $(for n in $CLIENTS; do echo "$OUTDIR/$n.crt"; done); do
    openssl verify -CAfile "$CA_CRT" "$crt" > /dev/null || {
        echo "error: $crt does not verify against $CA_CRT" >&2
        exit 1
    }
done

ABS=$(cd "$OUTDIR" && pwd)
for first in $CLIENTS; do break; done

cat <<EOF

Verified against the CA. Everything is in $ABS

server.conf:

    tls_cert = $ABS/server.crt
    tls_key  = $ABS/server.key
    tls_ca   = $ABS/ca.crt
    tls_verify_client = true

Client settings: enable TLS, then

    CA cert:            $ABS/ca.crt
    Client certificate: $ABS/$first.crt
    Client key:         $ABS/$first.key

Copy ca.crt and that client pair to the client machine. Set "CA cert" rather
than installing ca.crt system-wide: the system store would trust this CA for
every program on that machine, not just vrcd. Connect using one of the names
in the server certificate's SAN ($HOSTS), since the name is checked too.

Keep ca.key on the machine that issues certificates; the server and clients
never need it. Give each client its own certificate ($0 -c NAME), so one can
be dropped without reissuing the rest.
EOF
