#!/bin/zsh
# apicheck.sh <host[:port]> — checks every API call Proxima makes against that server's own API schema. No sign-in needed.
set -e
HOST=${1:?usage: Tools/apicheck.sh <host[:port]>}
[[ $HOST == *:* ]] || HOST="$HOST:8006"
DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The API viewer's schema is a public file on every node. Nodes use self-signed certificates, so curl doesn't verify it;
# nothing is sent, and the file is only read as data.
curl -sfk --max-time 60 "https://$HOST/pve-docs/api-viewer/apidoc.js" -o "$TMP/apidoc.js"
python3 -I "$DIR/Tools/apicheck.py" "$TMP/apidoc.js" "$DIR/Proxima"
