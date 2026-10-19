# frozen_string_literal: true

require 'fileutils'

module GHB
  # Removes the dependabot config and the retired cron dependency workflows.
  class DependabotManager
    def save
      dependabot_file = '.github/dependabot.yml'

      if File.exist?(dependabot_file)
        puts('    Removing dependabot config (CVE alerts are handled by repository settings)...')
        FileUtils.rm_f(dependabot_file)
      end

      FileUtils.rm_f('.github/workflows/dependencies.yml')
      FileUtils.rm_f('.github/workflows/soup.yml')
    end
  end
end
