#!/usr/bin/env ruby

# frozen_string_literal: true

require_relative '../lib/ghb/application'

begin
  exit(GHB::Application.new(ARGV).execute)
rescue GHB::ConfigError => e
  warn("Error: #{e.message}")
  exit(1)
rescue StandardError => e
  warn("Error: #{e.message}")
  warn(e.backtrace.join("\n")) if ENV['DEBUG']
  exit(1)
end
