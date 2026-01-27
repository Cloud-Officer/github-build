# frozen_string_literal: true

RSpec.describe(GHB::Status) do
  describe 'constants' do
    it 'defines SUCCESS_EXIT_CODE as 0' do
      expect(described_class::SUCCESS_EXIT_CODE).to(eq(0))
    end

    it 'defines ERROR_EXIT_CODE as 1' do
      expect(described_class::ERROR_EXIT_CODE).to(eq(1))
    end

    it 'defines FAILURE_EXIT_CODE as 2' do
      expect(described_class::FAILURE_EXIT_CODE).to(eq(2))
    end

    it 'makes constants publicly accessible' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      expect { described_class::SUCCESS_EXIT_CODE }
        .not_to(raise_error)
      expect { described_class::ERROR_EXIT_CODE }
        .not_to(raise_error)
      expect { described_class::FAILURE_EXIT_CODE }
        .not_to(raise_error)
    end
  end
end
