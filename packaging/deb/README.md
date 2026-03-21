# Debian packaging

This plugin can be packaged as a native-looking Smart Proxy `.deb` without running `gem install` on the target host.

## What it installs

- Plugin source tree under `/usr/share/foreman-proxy/vendor/smart_proxy_dhcp_mikrotik`
- Bundler hook under `/usr/share/foreman-proxy/bundler.d/dhcp_mikrotik.rb`
- Example config under `/etc/foreman-proxy/settings.d/dhcp_mikrotik.yml.example`

## Build

Requirements:

- `fpm`
- Ruby available on the build machine

Run:

```bash
cd TheForeman/Mikrotik/dhcp_mikrotik
./packaging/deb/build-deb.sh
```

By default the package depends on the Smart Proxy version from `../../smart-proxy/VERSION`.

Override if needed:

```bash
SMART_PROXY_VERSION=3.17.1 ./packaging/deb/build-deb.sh
```

## Result

The resulting package is named:

```bash
foreman-proxy-plugin-dhcp-mikrotik_<plugin-version>_all.deb
```
