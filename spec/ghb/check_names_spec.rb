# frozen_string_literal: true

RSpec.describe(GHB::CheckNames) do
  describe '.for_job' do
    it 'returns the bare name for a job without a matrix' do
      expect(described_class.for_job('Ruby Linter', nil)).to(eq(['Ruby Linter']))
    end

    it 'appends the matrix values when the name does not reference the matrix' do
      expect(described_class.for_job('Ruby Unit Tests', { matrix: { os: %w[ubuntu-latest macos-latest] } }))
        .to(eq(['Ruby Unit Tests (ubuntu-latest)', 'Ruby Unit Tests (macos-latest)']))
    end

    it 'substitutes a matrix expression in the name instead of appending the values' do
      expect(described_class.for_job('Setup action (${{ matrix.os }})', { matrix: { os: %w[ubuntu-latest macos-latest] } }))
        .to(eq(['Setup action (ubuntu-latest)', 'Setup action (macos-latest)']))
    end

    it 'substitutes compact and repeated matrix expressions across several axes' do
      expect(described_class.for_job('Tests ${{matrix.os}} / ${{ matrix.ruby }} on ${{ matrix.os }}', { matrix: { os: %w[ubuntu-latest], ruby: [3.4] } }))
        .to(eq(['Tests ubuntu-latest / 3.4 on ubuntu-latest']))
    end

    it 'substitutes values that only an include row adds' do
      expect(described_class.for_job('Build ${{ matrix.target }}', { matrix: { include: [{ target: 'arm64' }, { target: 'x64' }] } }))
        .to(eq(['Build arm64', 'Build x64']))
    end

    it 'cannot resolve a matrix key the matrix does not define' do
      expect(described_class.for_job('Setup (${{ matrix.arch }})', { matrix: { os: %w[ubuntu-latest] } })).to(be_nil)
    end

    it 'cannot resolve a non-matrix expression in a matrix job name' do
      expect(described_class.for_job('Setup ${{ matrix.os }} ${{ github.ref }}', { matrix: { os: %w[ubuntu-latest] } })).to(be_nil)
    end

    it 'cannot resolve an expression in the name of a job without a matrix' do
      expect(described_class.for_job('Deploy ${{ inputs.env }}', nil)).to(be_nil)
    end

    it 'cannot resolve a matrix built from an expression' do
      expect(described_class.for_job('Ruby Unit Tests', { matrix: '${{ fromJson(needs.variables.outputs.matrix) }}' })).to(be_nil)
    end
  end
end
