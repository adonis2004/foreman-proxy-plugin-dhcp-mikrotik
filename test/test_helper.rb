# frozen_string_literal: true

require 'test/unit'
require 'mocha/test_unit'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'smart_proxy'
require 'proxy/log'
require 'proxy/helpers'
require 'dhcp_common/dhcp_common'
require 'dhcp_common/server'
require 'dhcp_common/subnet'
require 'dhcp_mikrotik/plugin_configuration'

# Minimal SETTINGS stub for logging in tests
require 'ostruct'
Proxy::SETTINGS ||= OpenStruct.new(log_level: 'INFO', log_buffer: 2000, log_buffer_errors: 1000)
