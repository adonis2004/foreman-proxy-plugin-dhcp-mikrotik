# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'smart_proxy_dhcp_mikrotik'
  spec.version       = '0.1.1'
  spec.authors       = ['adonis2004']
  spec.email         = ['serbanadonis@gmail.com']

  spec.summary       = 'Foreman Smart Proxy provider: DHCP Mikrotik'
  spec.description   = 'A Foreman Smart Proxy DHCP provider for Mikrotik RouterOS.'
  spec.homepage      = 'https://github.com/adonis2004/foreman-proxy-plugin-dhcp-mikrotik'
  spec.license       = 'GPL-3.0-or-later'

  spec.files         = Dir['lib/**/*', 'config/settings.d/*.example', 'README.md']
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 3.0'
  spec.add_dependency 'smart_proxy', '= 3.17.1'
  spec.add_dependency 'net-ssh', '>= 6.1', '< 8.0'

  # Test files are not packaged by default; Rake will run them from the repo

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'homepage_uri' => spec.homepage
  }
end
