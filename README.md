# smart_proxy_dhcp_mikrotik

Foreman Smart Proxy DHCP provider plugin for Mikrotik RouterOS.

This plugin adds a `dhcp_mikrotik` provider to Smart Proxy and manages
RouterOS DHCP networks, reservations, and leases over SSH.

For a full operator, maintainer, and packaging guide, see `MANUAL.md`.

## Compatibility

- Smart Proxy `3.17.x`
- Debian and Ubuntu production packaging for `foreman-proxy` `3.17.x`
- Ruby `>= 3.0`

The gem dependency is constrained to the Smart Proxy `3.17.x` series, and the
Debian package depends on the matching `foreman-proxy` package line.

## Features

- Subnets, leases, and reservations via RouterOS CLI over SSH
- Add and delete reservations with collision checks
- Honors Smart Proxy managed subnet filtering from `dhcp.yml`
- Supports `free_ips` allocation flow and recently-used IP blacklisting
- Per-reservation RouterOS DHCP option sets
- Standard DHCP reservation options:
  - `hostname` -> option `12`
  - `PXEClient` -> option `60`
  - `nextServer` -> option `66`
  - `filename` -> option `67`
- Solaris Jumpstart and SUNW vendor payloads encoded into option `43`
- Huawei ZTP support for DHCP options `143` and `150`
- Configurable SSH host key verification and optional custom `known_hosts` file

## Development

Use this mode when you are working from local source checkouts of both this
plugin and Smart Proxy.

### Development prerequisites

- Smart Proxy source checkout
- This plugin source checkout
- Bundler available in the Smart Proxy Ruby environment

Recommended layout:

```text
TheForeman/
  smart-proxy/
  Mikrotik/
    dhcp_mikrotik/
```

### Development installation

1. In the Smart Proxy checkout, add the plugin to the Smart Proxy `Gemfile`:

```ruby
gem 'smart_proxy_dhcp_mikrotik', path: '../Mikrotik/dhcp_mikrotik'
```

2. Configure Smart Proxy DHCP in `config/settings.d/dhcp.yml`:

```yaml
:enabled: https
:use_provider: dhcp_mikrotik
:server: 127.0.0.1
#:subnets: [192.168.205.0/255.255.255.128]
#:ping_free_ip: true
```

3. Create `config/settings.d/dhcp_mikrotik.yml` from the example and adjust it
   for your RouterOS host:

```yaml
:host: 10.0.0.2
:port: 22
:username: admin
:password: secret
:servers: ["dhcp1"]
:host_key_verification: accept_new
#:known_hosts_file: /etc/foreman-proxy/mikrotik_known_hosts
#:mikrotik_debug_dump: false
#:blacklist_duration_minutes: 1800
```

4. Install dependencies and start Smart Proxy from source:

```bash
cd TheForeman/smart-proxy
bundle install
bundle exec ruby bin/smart-proxy
```

### Development testing

Run the plugin test suite from this repository:

```bash
cd TheForeman/Mikrotik/dhcp_mikrotik
bundle install
bundle exec rake test
bundle exec rubocop
```

## Production

Use this mode when Smart Proxy is installed as a package and managed by the
operating system.

### Production prerequisites

- `foreman-proxy` package in the `3.17.x` series
- `ruby-net-ssh`
- RouterOS reachable over SSH

Production systems should not use the development `path:` Gemfile entry.

### Production installation from Debian package

This is the recommended production path.

1. Build the package:

```bash
cd TheForeman/Mikrotik/dhcp_mikrotik
dpkg-buildpackage -us -uc -b
```

2. Install the resulting package on the Smart Proxy host:

```bash
sudo dpkg -i ../foreman-proxy-plugin-dhcp-mikrotik_0.1.1-*.deb
```

3. Enable the DHCP feature in `/etc/foreman-proxy/settings.d/dhcp.yml`:

```yaml
:enabled: https
:use_provider: dhcp_mikrotik
:server: 127.0.0.1
#:subnets: [192.168.205.0/255.255.255.128]
#:ping_free_ip: true
```

4. Create `/etc/foreman-proxy/settings.d/dhcp_mikrotik.yml` from the example
   file installed by the package:

```bash
sudo cp /etc/foreman-proxy/settings.d/dhcp_mikrotik.yml.example \
  /etc/foreman-proxy/settings.d/dhcp_mikrotik.yml
```

5. Edit `/etc/foreman-proxy/settings.d/dhcp_mikrotik.yml`:

```yaml
:host: 10.0.0.2
:port: 22
:username: admin
:password: secret
:servers: ["dhcp1"]
:host_key_verification: accept_new
#:known_hosts_file: /etc/foreman-proxy/mikrotik_known_hosts
#:mikrotik_debug_dump: false
#:blacklist_duration_minutes: 1800
```

6. Restart Smart Proxy:

```bash
sudo systemctl restart foreman-proxy
sudo systemctl status foreman-proxy
```

### Production installation from Ruby gem

Use this only if you are managing Smart Proxy outside the Debian package flow.

1. Build the gem:

```bash
cd TheForeman/Mikrotik/dhcp_mikrotik
gem build smart_proxy_dhcp_mikrotik.gemspec
```

2. Install the gem into the same Ruby environment used by Smart Proxy.

3. Add a bundler hook under `/usr/share/foreman-proxy/bundler.d/dhcp_mikrotik.rb`:

```ruby
gem 'smart_proxy_dhcp_mikrotik', '= 0.1.1'
```

4. Configure `/etc/foreman-proxy/settings.d/dhcp.yml` and
   `/etc/foreman-proxy/settings.d/dhcp_mikrotik.yml` as shown above.

5. Restart Smart Proxy.

## Configuration

Example plugin configuration is provided in
`config/settings.d/dhcp_mikrotik.yml.example`.

Available settings:

- `:host`: RouterOS host or IP
- `:port`: SSH port, default `22`
- `:username`: RouterOS username
- `:password`: RouterOS password
- `:servers`: optional DHCP server names used as a tie-breaker
- `:host_key_verification`: `accept_new`, `always`, `never`, or `accept_new_or_local_tunnel`
- `:known_hosts_file`: optional custom `known_hosts` file
- `:mikrotik_debug_dump`: verbose RouterOS output logging
- `:blacklist_duration_minutes`: recently-used IP blacklist duration for `free_ips`

Smart Proxy DHCP feature selection remains in `dhcp.yml`:

- `:enabled`
- `:use_provider`
- `:server`
- `:subnets`
- `:ping_free_ip`

## API examples

```bash
# List subnets
curl -sS http://localhost:8000/dhcp/

# List reservations and leases in a subnet
curl -sS http://localhost:8000/dhcp/1.1.1.0

# Find by IP or MAC
curl -sS http://localhost:8000/dhcp/1.1.1.0/ip/1.1.1.2
curl -sS http://localhost:8000/dhcp/1.1.1.0/mac/00:50:56:11:22:33

# Add
curl -sS -X POST \
  -d 'name=host01' \
  -d 'ip=1.1.1.3' \
  -d 'mac=00:50:56:aa:bb:cc' \
  -d 'network=1.1.1.0' \
  -d 'nextServer=10.99.100.10' \
  -d 'filename=pxelinux.0' \
  http://localhost:8000/dhcp/1.1.1.0

# Delete
curl -sS -X DELETE http://localhost:8000/dhcp/1.1.1.0/mac/00:50:56:aa:bb:cc
```

## Packaging and CI

### Gem build

```bash
gem build smart_proxy_dhcp_mikrotik.gemspec
```

### Debian package build

```bash
dpkg-buildpackage -us -uc -b
```

An additional helper build script is available:

```bash
./packaging/deb/build-deb.sh
```

### Continuous integration

- GitHub Actions: `.github/workflows/ci.yml`
- GitLab CI: `.gitlab-ci.yml`

The CI pipelines:

- fetch Smart Proxy source for the matching `3.17.1` validation job
- run unit tests
- run lint checks
- build the Ruby gem
- build the Debian package
- publish artifacts on tagged releases

## Limitations

- The plugin targets the Smart Proxy `3.17.x` series, not all Smart Proxy versions.
- RouterOS behavior still depends on the capabilities of the target RouterOS release.
- Unsupported vendor-specific DHCP options raise an explicit error instead of being silently ignored.
- Debug logging can expose sensitive RouterOS output and should stay disabled in production.

## License

This project is licensed under GPL-3.0-or-later. See `LICENSE`.
