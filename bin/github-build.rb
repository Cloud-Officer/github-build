#!/usr/bin/env ruby

# frozen_string_literal: true

require_relative '../lib/ghb/application'

begin
  exit(GHB::Application.new(ARGV).execute)
rescue StandardError => e
  puts(e)
  puts(e.backtrace)
  exit(1)
end
