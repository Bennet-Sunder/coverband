# frozen_string_literal: true

require File.expand_path("../../test_helper", File.dirname(__FILE__))

####
# Thanks for all the help SimpleCov https://github.com/colszowka/simplecov-html
# initial version of test pulled into Coverband from Simplecov 12/19/2018
####
describe Coverband::Utils::SourceFile do
  coverage_for_sample_rb = [nil, 1, 1, 1, nil, nil, 1, 0, nil, nil, nil, nil, nil, nil, nil, nil].freeze
  describe "a source file initialized with some coverage data" do
    subject do
      Coverband::Utils::SourceFile.new(source_fixture("sample.rb"), coverage_for_sample_rb)
    end

    it "has a filename" do
      assert subject.filename
    end

    it "has source equal to src" do
      assert_equal subject.source, subject.src
    end

    it "has a project filename which removes the project directory" do
      assert_equal "/test/fixtures/sample.rb", subject.project_filename
    end

    it "has source_lines equal to lines" do
      assert_equal subject.source_lines, subject.lines
    end

    it "has 16 source lines" do
      assert_equal 16, subject.lines.count
    end

    it "has all source lines of type Coverband::Utils::SourceFile::Line" do
      subject.lines.each do |line|
        assert line.is_a?(Coverband::Utils::SourceFile::Line)
      end
    end

    it "has 'class Foo' as line(2).source" do
      assert_equal "class Foo\n", subject.line(2).source
    end

    it "returns lines number 2, 3, 4, 7 for covered_lines" do
      assert_equal [2, 3, 4, 7], subject.covered_lines.map(&:line)
    end

    it "returns lines number 8 for missed_lines" do
      assert_equal [8], subject.missed_lines.map(&:line)
    end

    it "returns lines number 1, 5, 6, 9, 10, 16 for never_lines" do
      assert_equal [1, 5, 6, 9, 10, 16], subject.never_lines.map(&:line)
    end

    it "returns line numbers 11, 12, 13, 14, 15 for skipped_lines" do
      assert_equal [11, 12, 13, 14, 15], subject.skipped_lines.map(&:line)
    end

    it "has 80% covered_percent" do
      assert_equal 80.0, subject.covered_percent
    end

    it "working for nil last_updated_at" do
      assert_equal "not available", subject.last_updated_at
    end
  end

  describe "simulating potential Ruby 1.9 defect -- see Issue #56" do
    subject do
      Coverband::Utils::SourceFile.new(source_fixture("sample.rb"), coverage_for_sample_rb + [nil])
    end

    it "has 16 source lines regardless of extra data in coverage array" do
      # Do not litter test output with known warning
      capture_stderr { assert_equal 16, subject.lines.count }
    end

    it "prints a warning to stderr if coverage array contains more data than lines in the file" do
      captured_output = capture_stderr {
        subject.lines
      }

      assert(captured_output.match(/^Warning: coverage data/))
    end
  end

  describe "a file that is never relevant" do
    coverage_for_never_rb = [nil, nil].freeze

    subject do
      Coverband::Utils::SourceFile.new(source_fixture("never.rb"), coverage_for_never_rb)
    end

    it "has 0.0 covered_strength" do
      assert_equal 0.0, subject.covered_strength
    end

    it "has 0.0 covered_percent" do
      assert_equal 100.0, subject.covered_percent
    end
  end

  describe "a file where nothing is ever executed mixed with skipping #563" do
    coverage_for_skipped_rb = [nil, nil, nil, nil].freeze

    subject do
      Coverband::Utils::SourceFile.new(source_fixture("skipped.rb"), coverage_for_skipped_rb)
    end

    it "has 0.0 covered_strength" do
      assert_equal 0.0, subject.covered_strength
    end

    it "has 0.0 covered_percent" do
      assert_equal 0.0, subject.covered_percent
    end
  end

  describe "a file where everything is skipped and missed #563" do
    coverage_for_skipped_rb_2 = [nil, nil, 0, nil].freeze

    subject do
      Coverband::Utils::SourceFile.new(source_fixture("skipped.rb"), coverage_for_skipped_rb_2)
    end

    it "has 0.0 covered_strength" do
      assert_equal 0.0, subject.covered_strength
    end

    it "has 0.0 covered_percent" do
      assert_equal 0.0, subject.covered_percent
    end
  end

  describe "a file where everything is skipped/irrelevamt but executed #563" do
    coverage_for_skkiped_and_executed_rb = [nil, nil, 1, 1, 0, nil, nil, nil].freeze

    subject do
      Coverband::Utils::SourceFile.new(source_fixture("skipped_and_executed.rb"), coverage_for_skkiped_and_executed_rb)
    end

    it "has 0.0 covered_strength" do
      assert_equal 0.0, subject.covered_strength
    end

    it "has 0.0 covered_percent" do
      assert_equal 0.0, subject.covered_percent
    end
  end
end
