#!/bin/sh
# A scripted stand-in for the obscura CLI (Longx.Browser tests). Behaviour
# is picked by the URL path:
#   /page        → a rendered page on stdout, obscura's progress on stderr
#   /slow?N      → sleeps N seconds first (for timeouts / concurrency)
#   /fail        → obscura's navigation error on stderr, exit 1
#   /big         → 1 MB of html
# Anything else is served like /page. Flags are echoed to stderr as
# "args: ..." so tests can assert what was passed. `--version` prints what
# the real one prints (the system-binary detection reads it).
if [ "$1" = "--version" ]; then echo "obscura 0.2.2"; exit 0; fi
echo "args: $*" >&2
echo "env: OBSCURA_ALLOW_PRIVATE_NETWORK=${OBSCURA_ALLOW_PRIVATE_NETWORK:-}" >&2
url=""
for a in "$@"; do
  case "$a" in
    http://*|https://*) url="$a" ;;
  esac
done
dump=html
prev=""
for a in "$@"; do
  if [ "$prev" = "--dump" ]; then dump="$a"; fi
  prev="$a"
done
case "$url" in
  *slow?*)
    n=$(printf '%s' "$url" | sed 's/.*slow?//')
    sleep "$n" ;;
  *fail*)
    echo "Fetching $url..." >&2
    echo "Error: Failed to navigate to $url: Network error: connection refused" >&2
    exit 1 ;;
esac
echo "Fetching $url..." >&2
echo "Page loaded: $url - \"Fake page\"" >&2
case "$dump" in
  markdown) printf '# Rendered\n\nHello from JS\n' ;;
  text) printf 'Rendered\nHello from JS\n' ;;
  *)
    case "$url" in
      *big*) head -c 1048576 /dev/zero | tr '\0' 'x' ;;
      *) printf '<!DOCTYPE html>\n<html><head><title>Fake page</title><script>x()</script></head><body><nav>menu</nav><main><h1>Rendered</h1><p class="lead" data-x="1">Hello from <b>JS</b></p><a href="/x">link</a></main><footer>foot</footer></body></html>\n' ;;
    esac ;;
esac
