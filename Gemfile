# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

smart_proxy_path = ENV['SMART_PROXY_PATH']
smart_proxy_path = File.expand_path('../../smart-proxy', __dir__) if smart_proxy_path.to_s.empty?

# Tests and development run against a checked out Smart Proxy source tree.
if File.directory?(smart_proxy_path)
  gem 'smart_proxy', path: smart_proxy_path
else
  raise "smart-proxy source not found. Set SMART_PROXY_PATH or place the checkout at ../../smart-proxy"
end

# Development & linting
group :development, :test do
  gem 'rake'
  gem 'rubocop', require: false
  gem 'test-unit'
  gem 'mocha'
end
