#!/usr/bin/env ruby

# frozen_string_literal: true

require_relative '../lib/ghb/application'

begin
  exit(GHB::Application.new(ARGV).execute)
rescue StandardError => e
  warn("Error: #{e.message}")

  cause = e.cause

  while cause
    warn("  caused by: #{cause.class}: #{cause.message}")
    cause = cause.cause
  end

  warn(e.backtrace.join("\n")) if ENV['DEBUG']
  exit(1)
end
