# frozen_string_literal: true

RSpec.describe(GHB::LanguageJobBuilder, '#add_setup_options') do
  let(:options)       { instance_double(GHB::Options, strict_version_check: true)  }
  let(:workflow)      { GHB::Workflow.new('CI')                                    }
  let(:setup_options) { {}                                                         }

  let(:builder) do
    described_class.new(
      context: GHB::BuildContext.new(options: options, submodules: [], old_workflow: GHB::Workflow.new('CI'), new_workflow: workflow, file_cache: {}),
      unit_tests_conditions: 'true'
    )
  end

  context 'with a version file' do
    before do
      workflow.env[:'GO-VERSION'] = '1.24.0'
      allow(File).to(receive(:read).with('.go-version').and_return("1.25.0\n"))
      allow(File).to(receive(:write))
    end

    it 'rewrites a mismatched version file under strict_version_check', :aggregate_failures do
      expect(add_options(go_option, '.go-version')).to(eq(banner('WARNING: Value mismatch for GO-VERSION', 'Version file (.go-version): 1.25.0', 'Recommended value: 1.26.0', 'Updating .go-version to 1.26.0.')))
      expect(File).to(have_received(:write).with('.go-version', "1.26.0\n"))
      expect(workflow.env).not_to(have_key(:'GO-VERSION'))
      expect(setup_options).to(be_empty)
    end

    it 'keeps a mismatched version file without strict_version_check', :aggregate_failures do
      allow(options).to(receive(:strict_version_check).and_return(false))
      expect(add_options(go_option, '.go-version')).to(eq(banner('WARNING: Value mismatch for GO-VERSION', 'Version file (.go-version): 1.25.0', 'Recommended value: 1.26.0', 'Using version file.')))
      expect(File).not_to(have_received(:write))
      expect(workflow.env).not_to(have_key(:'GO-VERSION'))
    end

    it 'stays silent when the version file matches', :aggregate_failures do
      allow(File).to(receive(:read).with('.go-version').and_return("1.26.0\n"))
      expect(add_options(go_option, '.go-version')).to(be_empty)
      expect(File).not_to(have_received(:write))
      expect(workflow.env).not_to(have_key(:'GO-VERSION'))
    end

    it 'does not read the version file when the option has no recommended value', :aggregate_failures do
      add_options([{ name: 'go-version', value: nil }], '.go-version')
      expect(File).not_to(have_received(:read))
      expect(workflow.env).not_to(have_key(:'GO-VERSION'))
    end
  end

  context 'without a version file' do
    it 'adds the recommended value when the env has none', :aggregate_failures do
      expect(add_options(mongodb_option)).to(be_empty)
      expect(workflow.env[:'MONGODB-VERSION']).to(eq('8.0.0'))
      expect(setup_options['mongodb-version']).to(eq('${{env.MONGODB-VERSION}}'))
    end

    it 'skips an option with neither an existing nor a recommended value', :aggregate_failures do
      add_options([{ name: 'apt-packages', value: nil }])
      expect(workflow.env).not_to(have_key(:'APT-PACKAGES'))
      expect(setup_options).to(be_empty)
    end

    it 'updates a mismatched VERSION value under strict_version_check', :aggregate_failures do
      workflow.env[:'MONGODB-VERSION'] = '7.0'
      expect(add_options(mongodb_option)).to(eq(banner('WARNING: Value mismatch for MONGODB-VERSION', 'Existing value: 7.0', 'Recommended value: 8.0.0', 'Updating MONGODB-VERSION to 8.0.0.')))
      expect(workflow.env[:'MONGODB-VERSION']).to(eq('8.0.0'))
      expect(setup_options['mongodb-version']).to(eq('${{env.MONGODB-VERSION}}'))
    end

    it 'keeps a mismatched VERSION value without strict_version_check', :aggregate_failures do
      allow(options).to(receive(:strict_version_check).and_return(false))
      workflow.env[:'MONGODB-VERSION'] = '7.0'
      expect(add_options(mongodb_option)).to(eq(banner('WARNING: Value mismatch for MONGODB-VERSION', 'Existing value: 7.0', 'Recommended value: 8.0.0', 'Using existing value.')))
      expect(workflow.env[:'MONGODB-VERSION']).to(eq('7.0'))
    end

    it 'keeps a mismatched non-VERSION value even under strict_version_check', :aggregate_failures do
      workflow.env[:'APT-PACKAGES'] = 'curl'
      expect(add_options([{ name: 'apt-packages', value: 'wget' }])).to(eq(banner('WARNING: Value mismatch for APT-PACKAGES', 'Existing value: curl', 'Recommended value: wget', 'Using existing value.')))
      expect(workflow.env[:'APT-PACKAGES']).to(eq('curl'))
    end

    it 'keeps an existing value silently when there is no recommended value', :aggregate_failures do
      workflow.env[:'APT-PACKAGES'] = 'curl'
      expect(add_options([{ name: 'apt-packages', value: nil }])).to(be_empty)
      expect(workflow.env[:'APT-PACKAGES']).to(eq('curl'))
      expect(setup_options['apt-packages']).to(eq('${{env.APT-PACKAGES}}'))
    end
  end

  it 'frames the warning banner identically from the version-file and env-merge paths' do
    allow(File).to(receive_messages(read: "1.25.0\n", write: nil))
    workflow.env[:'MONGODB-VERSION'] = '7.0'
    version_file_frame = banner_frame(add_options(go_option, '.go-version'))
    expect(banner_frame(add_options(mongodb_option))).to(eq(version_file_frame))
  end

  private

  def go_option
    [{ name: 'go-version', value: '1.26.0' }]
  end

  def mongodb_option
    [{ name: 'mongodb-version', value: '8.0.0' }]
  end

  def banner(*lines)
    stars = '*' * 80
    "\e[31m\n#{stars}\n#{lines.join("\n")}\n#{stars}\n\e[0m\n"
  end

  def banner_frame(text)
    lines = text.lines
    lines.values_at(0, 1, -2, -1) + [lines[2][/\AWARNING: Value mismatch for /], lines[4][/\ARecommended value: /], lines.size]
  end

  def add_options(setup, version_file = nil)
    capture_stdout { builder.__send__(:add_setup_options, setup_options, setup, version_file) }
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
