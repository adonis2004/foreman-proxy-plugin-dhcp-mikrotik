# frozen_string_literal: true

# Load the Mikrotik DHCP provider plugin
# Ensure configuration loader class is defined before plugin DSL references it
require 'dhcp_mikrotik/plugin_configuration'
require 'dhcp_mikrotik/dhcp_mikrotik_plugin'
