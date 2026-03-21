#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMART_PROXY_VERSION="${SMART_PROXY_VERSION:-$(cat "$ROOT_DIR/../../smart-proxy/VERSION")}"
GEM_VERSION="${GEM_VERSION:-$(ruby -e "spec = Gem::Specification.load('$ROOT_DIR/smart_proxy_dhcp_mikrotik.gemspec'); puts spec.version")}"
PKG_NAME="${PKG_NAME:-foreman-proxy-plugin-dhcp-mikrotik}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/pkg/deb-build}"
VENDOR_DIR="/usr/share/foreman-proxy/vendor/smart_proxy_dhcp_mikrotik"
BUNDLER_DIR="/usr/share/foreman-proxy/bundler.d"
SETTINGS_DIR="/etc/foreman-proxy/settings.d"
SMART_PROXY_NEXT_VERSION="${SMART_PROXY_NEXT_VERSION:-$(ruby -e "parts = '$SMART_PROXY_VERSION'.split('.').map(&:to_i); parts[-1] += 1; puts parts.join('.')")}"

if ! command -v fpm >/dev/null 2>&1; then
  echo "fpm is required to build the .deb package" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p \
  "$BUILD_DIR$VENDOR_DIR" \
  "$BUILD_DIR$BUNDLER_DIR" \
  "$BUILD_DIR$SETTINGS_DIR"

cp -R \
  "$ROOT_DIR/lib" \
  "$ROOT_DIR/config" \
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/smart_proxy_dhcp_mikrotik.gemspec" \
  "$BUILD_DIR$VENDOR_DIR/"

cat > "$BUILD_DIR$BUNDLER_DIR/dhcp_mikrotik.rb" <<EOF
gem 'smart_proxy_dhcp_mikrotik', '= ${GEM_VERSION}', path: '${VENDOR_DIR}'
EOF

cp "$ROOT_DIR/config/settings.d/dhcp_mikrotik.yml.example" \
  "$BUILD_DIR$SETTINGS_DIR/dhcp_mikrotik.yml.example"

mkdir -p "$ROOT_DIR/pkg"

fpm -s dir -t deb \
  -n "$PKG_NAME" \
  -v "$GEM_VERSION" \
  --architecture all \
  --description "Foreman Smart Proxy DHCP Mikrotik plugin" \
  --license "GPL-3.0-or-later" \
  --depends "foreman-proxy (>= ${SMART_PROXY_VERSION})" \
  --depends "foreman-proxy (<< ${SMART_PROXY_NEXT_VERSION})" \
  -C "$BUILD_DIR" \
  .
