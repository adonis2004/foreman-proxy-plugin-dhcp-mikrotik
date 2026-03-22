# smart_proxy_dhcp_mikrotik Manual

## 1. Purpose

`smart_proxy_dhcp_mikrotik` is a Foreman Smart Proxy DHCP provider plugin for
Mikrotik RouterOS. It allows Smart Proxy to manage DHCP reservations, query
subnets, inspect active leases, and allocate free IP addresses by talking to
RouterOS over SSH.

This manual is intended to be the detailed operational guide for the plugin.
It complements the shorter `README.md` and is written for administrators,
developers, packagers, and maintainers.

## 2. Scope and compatibility

The current implementation targets:

- Smart Proxy `3.17.x`
- Ruby `>= 3.0`
- Debian and Ubuntu package installations of `foreman-proxy`
- RouterOS devices reachable over SSH

The gemspec enforces the Smart Proxy `3.17.x` line at the Ruby dependency
level, and the Debian package enforces the same compatibility range at the
system package level.

## 3. What the plugin does

At a high level, the plugin:

- registers a Smart Proxy DHCP provider named `dhcp_mikrotik`
- exposes DHCP capability flags for filename handling
- uses the Smart Proxy `free_ips` service for unused IP allocation
- connects to RouterOS via `net-ssh`
- reads DHCP networks and leases from RouterOS CLI output
- creates static leases for Foreman reservations
- removes RouterOS leases when Smart Proxy deletes a reservation
- builds RouterOS DHCP option definitions and option sets per reservation

## 4. Repository layout

Important files in the repository:

- `README.md`
  - short usage guide and install overview
- `MANUAL.md`
  - this detailed manual
- `smart_proxy_dhcp_mikrotik.gemspec`
  - gem metadata and runtime dependency bounds
- `Gemfile`
  - development and test setup, plus the Smart Proxy source dependency
- `Rakefile`
  - test task
- `config/settings.d/dhcp_mikrotik.yml.example`
  - example plugin configuration
- `lib/smart_proxy_dhcp_mikrotik.rb`
  - gem entry point
- `lib/dhcp_mikrotik/dhcp_mikrotik_plugin.rb`
  - Smart Proxy plugin registration and default settings
- `lib/dhcp_mikrotik/dhcp_mikrotik_main.rb`
  - provider implementation used by Smart Proxy DHCP APIs
- `lib/dhcp_mikrotik/plugin_configuration.rb`
  - RouterOS client and dependency injection wiring
- `debian/`
  - full Debian source package metadata
- `packaging/deb/build-deb.sh`
  - alternative FPM-based `.deb` builder
- `test/`
  - unit tests for parsing, option support, and provider guardrails
- `.github/workflows/ci.yml`
  - GitHub Actions pipeline
- `.gitlab-ci.yml`
  - GitLab CI pipeline

## 5. Architecture

### 5.1 Entry points

The runtime entry point is `lib/smart_proxy_dhcp_mikrotik.rb`.
It loads:

- `dhcp_mikrotik/plugin_configuration`
- `dhcp_mikrotik/dhcp_mikrotik_plugin`

The production Debian package activates the gem through:

- `debian/dhcp_mikrotik.rb`

That bundler hook is installed into:

- `/usr/share/foreman-proxy/bundler.d/dhcp_mikrotik.rb`

### 5.2 Smart Proxy plugin registration

The Smart Proxy plugin definition lives in
`lib/dhcp_mikrotik/dhcp_mikrotik_plugin.rb`.

It registers:

- plugin id: `:dhcp_mikrotik`
- plugin version: `0.1.1`
- capability: `dhcp_filename_ipv4`
- capability: `dhcp_filename_hostname`

It also:

- declares a dependency on the DHCP subsystem
- starts the `free_ips` service
- sets default settings for:
  - `blacklist_duration_minutes`
  - `mikrotik_debug_dump`
  - `host_key_verification`

### 5.3 Dependency injection

Dependency injection is handled in
`lib/dhcp_mikrotik/plugin_configuration.rb`.

The plugin wires three important dependencies:

- `:free_ips`
  - Smart Proxy helper used for unused IP selection
- `:mtik_client`
  - RouterOS SSH client
- `:dhcp_provider`
  - the provider object exposed to Smart Proxy DHCP

### 5.4 Provider responsibilities

The provider class in `lib/dhcp_mikrotik/dhcp_mikrotik_main.rb` is responsible
for Smart Proxy-facing behavior:

- listing managed subnets
- listing reservations and dynamic leases
- finding records by IP or MAC
- adding reservations
- deleting reservations
- calculating or reusing an unused IP
- validating that requested IPs belong to the target subnet

### 5.5 RouterOS client responsibilities

The `MikrotikClient` in `lib/dhcp_mikrotik/plugin_configuration.rb` is
responsible for RouterOS communication and parsing:

- opening SSH connections
- executing RouterOS CLI commands
- parsing printed DHCP server, network, pool, and lease output
- mapping network settings into Smart Proxy DHCP options
- creating RouterOS DHCP option records
- creating RouterOS DHCP option-set records
- creating and deleting static DHCP leases

## 6. Runtime behavior

### 6.1 Subnet discovery

When Smart Proxy asks for subnets, the provider:

1. asks RouterOS for DHCP network data
2. parses the RouterOS network records
3. converts CIDR prefixes to dotted netmasks
4. filters the result through Smart Proxy managed subnet rules from `dhcp.yml`
5. returns `Proxy::DHCP::Subnet` objects

The provider honors Smart Proxy subnet filtering through `:subnets` in
`dhcp.yml`. That means the plugin can be limited to only the networks that
Foreman should manage, even if RouterOS has more DHCP networks configured.

### 6.2 Lease and reservation discovery

RouterOS does not expose lease objects in the same shape as Smart Proxy, so the
plugin maps RouterOS records into:

- `Proxy::DHCP::Reservation`
- `Proxy::DHCP::Lease`

The current distinction is based on whether RouterOS marks the lease as dynamic
or not.

### 6.3 Reservation creation

When Foreman requests a DHCP reservation, the provider:

1. normalizes the incoming request
2. validates the MAC address
3. ensures a hostname is present
4. resolves the target subnet
5. checks for collisions by IP and MAC
6. ignores collisions that belong to `related_macs`
7. verifies the requested IP is inside the subnet
8. asks the RouterOS client to create the static lease

### 6.4 Free IP allocation

When Smart Proxy asks for an unused IP, the provider:

1. tries to read the Mikrotik address pool range for the subnet
2. if available, uses the pool range as the allocation range
3. if explicit `from` and `to` values are provided, intersects them with the
   pool range
4. if no pool range exists, falls back to the subnet network and netmask
5. reuses an existing reservation for the same MAC if it is already inside the
   target range
6. otherwise delegates to Smart Proxy `free_ips`

## 7. RouterOS command model

The plugin uses RouterOS CLI commands executed over SSH. It does not currently
use an API client library or HTTPS-based RouterOS integration.

Typical command families used by the plugin:

- `/ip dhcp-server network print detail without-paging`
- `/ip dhcp-server lease print detail without-paging`
- `/ip pool print detail without-paging`
- `/ip dhcp-server option add`
- `/ip dhcp-server option-set add`
- `/ip dhcp-server lease add`
- `/ip dhcp-server lease remove`

This design keeps the implementation lightweight, but it also means the parser
depends on RouterOS textual output staying compatible.

## 8. Configuration

### 8.1 Smart Proxy DHCP settings

Smart Proxy feature-level configuration stays in `dhcp.yml`.

Typical production example:

```yaml
:enabled: https
:use_provider: dhcp_mikrotik
:server: 127.0.0.1
#:subnets: [192.168.205.0/255.255.255.128]
#:ping_free_ip: true
```

Meaning of the important keys:

- `:enabled`
  - enables the DHCP feature
- `:use_provider`
  - must be `dhcp_mikrotik` to activate this plugin
- `:server`
  - logical server value used by Smart Proxy
- `:subnets`
  - optional managed subnet filter
- `:ping_free_ip`
  - standard Smart Proxy free-IP behavior

### 8.2 Plugin-specific settings

Plugin settings live in `dhcp_mikrotik.yml`.

Available settings:

- `:host`
  - RouterOS hostname or IP
- `:port`
  - SSH port, default `22`
- `:username`
  - RouterOS username
- `:password`
  - RouterOS password
- `:servers`
  - optional DHCP server names used as an explicit tie-breaker
- `:host_key_verification`
  - one of:
    - `accept_new`
    - `always`
    - `never`
    - `accept_new_or_local_tunnel`
- `:known_hosts_file`
  - optional custom known_hosts file for RouterOS SSH keys
- `:mikrotik_debug_dump`
  - enables verbose logging of RouterOS responses
- `:blacklist_duration_minutes`
  - Smart Proxy `free_ips` blacklist duration

Example:

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

### 8.3 Notes about `use_tls`

The constructor receives a `use_tls` value from Smart Proxy settings, but the
current implementation talks to RouterOS over SSH only. There is no HTTPS or
TLS transport path for RouterOS management in this plugin at the moment.

## 9. DHCP option support

One of the most important parts of this plugin is DHCP option translation.
Instead of only creating a static lease, the plugin can also build RouterOS
custom options and option sets for a reservation.

### 9.1 Standard option support

Supported standard reservation options:

- `hostname` -> DHCP option `12`
- `PXEClient` -> DHCP option `60`
- `nextServer` -> DHCP option `66`
- `filename` -> DHCP option `67`

These are turned into RouterOS DHCP option entries and attached to the
reservation through a RouterOS DHCP option-set.

### 9.2 Vendor option support

The plugin accepts certain vendor-formatted reservation keys and maps them into
RouterOS raw option data.

Currently supported vendor family:

- SUNW / Solaris / SPARC style vendor entries mapped into DHCP option `43`

Supported SUNW-style attributes include:

- `root_server_ip`
- `root_server_hostname`
- `root_path_name`
- `install_server_ip`
- `install_server_name`
- `install_path`
- `sysid_server_path`
- `jumpstart_server_path`

Unsupported vendor keys are rejected with an explicit Smart Proxy DHCP error.
They are not silently ignored.

### 9.3 Huawei ZTP support

For Huawei-style ZTP flows, the plugin supports:

- DHCP option `143`
  - encoded from `ztp_vendor` and `ztp_firmware`
- DHCP option `150`
  - encoded from `nextServer`

The current `143` logic is intentionally narrow and expects:

- `ztp_vendor` equal to `huawei`
- a `filename` that matches `ztp.cfg...`
- `ztp_firmware` to contain `:core` and `:web`

### 9.4 Option-set naming and reuse

The plugin hashes the option definition names to produce stable RouterOS
option-set names. This reduces duplicate option-set creation when reservations
use the same effective option bundle.

## 10. Server selection behavior

When creating a reservation, the plugin tries to determine which RouterOS DHCP
server should own the lease.

Selection order:

1. use the DHCP server associated with the matching RouterOS network
2. if RouterOS exposes only one DHCP server, use that one
3. if `:servers` is configured, use its first entry as a tie-breaker
4. if multiple servers exist and no match can be determined, raise an error

This makes the `:servers` setting a fallback hint rather than the primary
source of truth.

## 11. Development setup

Use development mode when you are working with Smart Proxy source and plugin
source together.

Recommended source layout:

```text
TheForeman/
  smart-proxy/
  Mikrotik/
    dhcp_mikrotik/
```

### 11.1 Gemfile integration

In the Smart Proxy source checkout, add:

```ruby
gem 'smart_proxy_dhcp_mikrotik', path: '../Mikrotik/dhcp_mikrotik'
```

### 11.2 Required Smart Proxy source checkout

The plugin `Gemfile` expects access to a Smart Proxy source tree for local
development and tests. It resolves that tree either from:

- the `SMART_PROXY_PATH` environment variable
- or `../../smart-proxy` relative to the plugin directory

If neither exists, Bundler raises an error.

### 11.3 Starting Smart Proxy from source

Example:

```bash
cd TheForeman/smart-proxy
bundle install
bundle exec ruby bin/smart-proxy
```

### 11.4 Development test commands

From the plugin repo:

```bash
bundle install
bundle exec rake test
bundle exec rubocop
gem build smart_proxy_dhcp_mikrotik.gemspec
```

## 12. Production installation

Production systems should use either the Debian package or a Ruby gem installed
into the same runtime used by Smart Proxy. They should not use a development
`path:` Gemfile entry.

### 12.1 Production path A: Debian package

This is the recommended production approach for Debian and Ubuntu.

Build:

```bash
dpkg-buildpackage -us -uc -b
```

Install:

```bash
sudo dpkg -i ../foreman-proxy-plugin-dhcp-mikrotik_0.1.1-*.deb
```

The package installs:

- gem content into:
  - `/usr/share/rubygems-integration/all/gems/smart_proxy_dhcp_mikrotik-0.1.1`
- gemspec stub into:
  - `/usr/share/rubygems-integration/all/specifications/`
- bundler hook into:
  - `/usr/share/foreman-proxy/bundler.d/dhcp_mikrotik.rb`
- example config into:
  - `/etc/foreman-proxy/settings.d/dhcp_mikrotik.yml.example`

Why the gemspec stub exists:

- packaged `foreman-proxy` is not exposed as the RubyGems `smart_proxy` gem
- therefore production package compatibility is enforced by Debian package
  dependencies, not by the Debian-installed gemspec stub

### 12.2 Production path B: Ruby gem

Use this only if Smart Proxy is managed outside the Debian package path.

Build:

```bash
gem build smart_proxy_dhcp_mikrotik.gemspec
```

Install the gem into the same Ruby runtime used by Smart Proxy, then add:

```ruby
gem 'smart_proxy_dhcp_mikrotik', '= 0.1.1'
```

to:

- `/usr/share/foreman-proxy/bundler.d/dhcp_mikrotik.rb`

Then configure:

- `/etc/foreman-proxy/settings.d/dhcp.yml`
- `/etc/foreman-proxy/settings.d/dhcp_mikrotik.yml`

and restart Smart Proxy.

### 12.3 Service restart

Typical packaged deployment restart:

```bash
sudo systemctl restart foreman-proxy
sudo systemctl status foreman-proxy
```

## 13. Debian packaging details

The repository contains two packaging approaches.

### 13.1 Preferred packaging path: `debian/`

The full Debian source package under `debian/` is the preferred production
packaging route.

Important files:

- `debian/control`
  - package metadata and dependency bounds
- `debian/rules`
  - install logic and test behavior
- `debian/foreman-proxy-plugin-dhcp-mikrotik.install`
  - install map for gem content, bundler hook, and example config
- `debian/smart_proxy_dhcp_mikrotik.gemspec.stub`
  - production gemspec stub

The Debian package currently:

- depends on `foreman-proxy >= 3.17` and `< 3.18`
- depends on `ruby-net-ssh`
- skips `dh_auto_test`
- expects testing to be performed from the source tree

### 13.2 Alternate packaging path: `packaging/deb/build-deb.sh`

The repository also includes an FPM-based builder.

This helper:

- copies plugin files into a build staging tree
- generates a bundler hook that uses a `path:` gem reference
- builds a `.deb` with `fpm`

This path is useful for quick package generation but is less native than the
full Debian packaging path in `debian/`.

## 14. CI and release workflow

### 14.1 GitHub Actions

The GitHub Actions workflow:

- checks out the plugin
- checks out Smart Proxy `3.17.1`
- runs the test suite
- builds the gem
- builds the Debian package
- uploads artifacts
- creates a GitHub release on version tags

### 14.2 GitLab CI

The GitLab pipeline:

- clones Smart Proxy `3.17.1`
- installs dependencies
- runs tests
- builds the gem
- builds the Debian package
- uploads artifacts
- publishes tagged release artifacts to the GitLab Generic Package Registry

### 14.3 Tagging model

Both CI systems are designed to publish release artifacts on version tags such
as:

```text
v0.1.1
```

## 15. Test coverage

The repository includes focused unit tests.

### 15.1 Parsing and client tests

`test/mikrotik_client_parsing_test.rb` covers:

- CIDR to netmask conversion
- RouterOS network parsing
- server selection logic
- option-set creation
- standard DHCP option encodings
- Huawei ZTP option handling
- SUNW option `43` payload generation
- validation of unsupported vendor options
- SSH known_hosts and host key verification behavior

### 15.2 Provider guardrail tests

`test/provider_guardrails_test.rb` covers:

- rejecting reservation requests outside the subnet
- honoring Smart Proxy managed subnet filters
- allowing `related_macs` to bypass conflict checks

## 16. API usage examples

Example Smart Proxy API usage:

```bash
# List subnets
curl -sS http://localhost:8000/dhcp/

# List reservations and leases in a subnet
curl -sS http://localhost:8000/dhcp/1.1.1.0

# Query by IP or MAC
curl -sS http://localhost:8000/dhcp/1.1.1.0/ip/1.1.1.2
curl -sS http://localhost:8000/dhcp/1.1.1.0/mac/00:50:56:11:22:33

# Create a reservation
curl -sS -X POST \
  -d 'name=host01' \
  -d 'ip=1.1.1.3' \
  -d 'mac=00:50:56:aa:bb:cc' \
  -d 'network=1.1.1.0' \
  -d 'nextServer=10.99.100.10' \
  -d 'filename=pxelinux.0' \
  http://localhost:8000/dhcp/1.1.1.0

# Delete by MAC
curl -sS -X DELETE http://localhost:8000/dhcp/1.1.1.0/mac/00:50:56:aa:bb:cc
```

## 17. Logging and diagnostics

### 17.1 Standard logging

The plugin uses Smart Proxy logging facilities through `Proxy::Log`.

### 17.2 Verbose Mikrotik logging

If `:mikrotik_debug_dump` is enabled, the client logs full RouterOS command
output instead of a shortened sample.

This is useful for troubleshooting parsing and command behavior, but it can
expose sensitive operational data and should normally stay disabled in
production.

### 17.3 Common troubleshooting areas

If the plugin does not behave as expected, check:

- Smart Proxy is actually using `:use_provider: dhcp_mikrotik`
- RouterOS SSH connectivity works from the Smart Proxy host
- the Smart Proxy runtime can load the plugin gem
- `:host`, `:username`, and `:password` are valid
- managed subnet filters in `dhcp.yml` are not excluding the target network
- the RouterOS network has a DHCP server and, ideally, a named address pool
- the target RouterOS host key policy matches your deployment

## 18. Limitations and operational caveats

- The plugin is limited to Smart Proxy `3.17.x`.
- The RouterOS integration is based on CLI output parsing.
- Unsupported vendor DHCP options raise errors.
- Some advanced or vendor-specific DHCP behaviors beyond the implemented
  standard, SUNW, and Huawei cases are not supported.
- The code accepts `use_tls` from settings, but RouterOS management still uses
  SSH only.

## 19. Recommended production practices

- Prefer the Debian package over an ad hoc gem install on Debian or Ubuntu.
- Use `host_key_verification: always` when you can pre-manage SSH host keys.
- Set `known_hosts_file` explicitly if you want an isolated trust store.
- Keep `mikrotik_debug_dump` disabled except during troubleshooting.
- Constrain Smart Proxy management with `:subnets` if the RouterOS device
  serves more networks than Foreman should control.
- Treat the `:servers` list as a fallback hint, not the primary source of truth.

## 20. Maintenance checklist

When updating the plugin:

1. adjust code and tests
2. run:
   - `bundle exec rake test`
   - `bundle exec rubocop`
   - `gem build smart_proxy_dhcp_mikrotik.gemspec`
3. verify Debian packaging with:
   - `dpkg-buildpackage -us -uc -b`
4. update documentation
5. push changes
6. tag a release if artifacts should be published

## 21. License

This project is licensed under GPL-3.0-or-later.
See `LICENSE` for the full license text.
