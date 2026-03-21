# smart_proxy_dhcp_mikrotik

Foreman Smart Proxy provider: DHCP Mikrotik (RouterOS)

Status: working provider with SSH-based client, PXE 66/67 support, server auto-mapping, and unit tests.

## Install (development)

1) In the Smart Proxy checkout (`TheForeman/smart-proxy`), add the gem to `Gemfile`:

```ruby
gem 'smart_proxy_dhcp_mikrotik', path: '../Mikrotik/dhcp_mikrotik'
```

2) Select the provider in `config/settings.d/dhcp.yml`:

```yaml
:enabled: https
:use_provider: dhcp_mikrotik
:server: 127.0.0.1        # logical identifier for the proxy
#:subnets: [192.168.205.0/255.255.255.128]
#:ping_free_ip: true
```

3) Configure Mikrotik settings in `config/settings.d/dhcp_mikrotik.yml`:

```yaml
:host: 10.0.0.2
:port: 22
:username: admin
:password: secret
:servers: ["dhcp1"]       # optional tie-breaker when multiple DHCP servers exist
#:mikrotik_debug_dump: false
#:blacklist_duration_minutes: 1800
```

4) Start or restart Smart Proxy and verify the DHCP feature is exposed.

For a development checkout:

```bash
cd TheForeman/smart-proxy
bundle install
bundle exec ruby bin/smart-proxy
```

## Production install

For packaged Smart Proxy installs, use one of these:

1. Ruby gem deployment

Install the gem into the Smart Proxy Ruby environment, then add a bundler hook under `/usr/share/foreman-proxy/bundler.d/` and config under `/etc/foreman-proxy/settings.d/`.

2. Native `.deb` deployment

Build a package that installs the plugin as a Debian Ruby gem under `/usr/share/rubygems-integration/all/gems/smart_proxy_dhcp_mikrotik-0.1.1`, adds a gemspec stub under `/usr/share/rubygems-integration/all/specifications/`, installs `/usr/share/foreman-proxy/bundler.d/dhcp_mikrotik.rb`, and drops the example config into `/etc/foreman-proxy/settings.d/`.

This repository includes a helper for the second approach:

```bash
./packaging/deb/build-deb.sh
```

There is also a full Debian packaging layout in `debian/` for production builds:

```bash
dpkg-buildpackage -us -uc -b
```

That package is intended to work on both Debian and Ubuntu, as long as the
required Foreman repository packages are present, especially:

- `foreman-proxy` in the `3.17.1` package series
- `ruby-net-ssh`

## CI

This repository includes CI for both GitHub and GitLab:

- GitHub Actions: `.github/workflows/ci.yml`
- GitLab CI: `.gitlab-ci.yml`

Both pipelines:

- fetch Smart Proxy source `3.17.1` for the test job
- run `bundle exec rake test`
- build `smart_proxy_dhcp_mikrotik-*.gem`
- build the Debian package with `dpkg-buildpackage -b`
- publish the built artifacts

The CI jobs keep their cloned Smart Proxy source in `tmp/smart-proxy-source` and release artifacts in `pkg/artifacts`.
That path used to be `_ci`; it was only a temporary CI scratch directory, not a Foreman convention.

Tag-based releases are also configured:

- GitHub: pushing a tag like `v0.1.1` creates a GitHub release and uploads the `.gem` and `.deb`
- GitLab: pushing a tag like `v0.1.1` creates a GitLab release and uploads package files to the Generic Package Registry

## Features

- Subnets, leases, and reservations via RouterOS CLI over SSH
- Add/delete reservations with collision checks and IP-in-subnet guardrails
- Honors `dhcp.yml` managed subnet filtering (`:subnets`) and `:ping_free_ip`
- Auto-selection of DHCP server (per-network -> single server -> optional first from `:servers`)
- PXE options 66/67 per reservation via RouterOS DHCP options and option-sets
- Optional deep debug logging with `:mikrotik_debug_dump`

## PXE options (66/67)

Include `nextServer` (option 66) and/or `filename` (option 67) in the POST body. The provider creates or reuses corresponding RouterOS DHCP options and a combined option-set, then assigns it to the lease.

Example:

```bash
network=1.1.1.0
ip=1.1.1.2
mac=00:50:56:11:22:33
curl -sS -X POST \
  -d "name=test-mtik-pxe" \
  -d "ip=${ip}" \
  -d "mac=${mac}" \
  -d "network=${network}" \
  -d "nextServer=10.99.100.10" \
  -d "filename=pxelinux.0" \
  http://localhost:8000/dhcp/${network}
```

## API usage

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
  http://localhost:8000/dhcp/1.1.1.0

# Delete
curl -sS -X DELETE http://localhost:8000/dhcp/1.1.1.0/mac/00:50:56:aa:bb:cc
```

## Tests

```bash
cd TheForeman/Mikrotik/dhcp_mikrotik
bundle install
bundle exec rake test
```

## Packaging

```bash
cd TheForeman/Mikrotik/dhcp_mikrotik
gem build smart_proxy_dhcp_mikrotik.gemspec
gem install ./smart_proxy_dhcp_mikrotik-0.1.1.gem
```

Then depend on it from Smart Proxy:

```ruby
gem 'smart_proxy_dhcp_mikrotik', '~> 0.1'
```

## Notes

- This provider re-queries RouterOS on demand, so router-side DHCP changes appear without restarting Smart Proxy.
- Disable `:mikrotik_debug_dump` in production because it can log sensitive RouterOS output.
