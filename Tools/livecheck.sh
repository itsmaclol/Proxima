#!/bin/zsh
# Checks a Proxmox server with Proxima's own networking code, without signing in:
# certificate pinning, realms, 401 handling and error decoding. Doesn't need the app's Local Network permission.
# Usage: Tools/livecheck.sh 192.168.1.10   (or host:port)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -ge 1 ]] || { echo "usage: $0 <host[:port]>"; exit 2; }
host=${1%%:*}; port=${1##*:}; [[ "$port" == "$1" ]] && port=8006
fingerprint=$(echo | openssl s_client -connect "$host:$port" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
build=$(mktemp -d)
swiftc -O -parse-as-library -swift-version 6 -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
    Tools/LiveCheck.swift Proxima/Core/*.swift Proxima/API/*.swift -o "$build/livecheck"
"$build/livecheck" "$host:$port" "$fingerprint"
