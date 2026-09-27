#!/bin/sh
# A stand-in for longx-cert (Longx.Tls tests): `obtain` writes its stdin to
# $FAKE_CERT_REQUEST, prints the file $FAKE_CERT_RESULT and exits with
# $FAKE_CERT_EXIT (0 by default); lego's log is imitated on stderr.
case "$1" in
  --version) echo "longx-cert v0.1.0 (lego v5.5.2)"; exit 0 ;;
  obtain)
    cat > "${FAKE_CERT_REQUEST:-/dev/null}"
    echo '{"level":"INFO","msg":"acme: Obtaining bundled SAN certificate"}' >&2
    cat "$FAKE_CERT_RESULT"
    exit "${FAKE_CERT_EXIT:-0}"
    ;;
  *) echo "usage" >&2; exit 2 ;;
esac
