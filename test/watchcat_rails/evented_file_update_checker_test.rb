# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class WatchcatRails::EventedFileUpdateCheckerTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("watchcat_rails")
  end

  def teardown
    FileUtils.remove_entry_secure(@tmpdir)
  end

  def test_initialization_requires_block
    assert_raises(ArgumentError) do
      WatchcatRails::EventedFileUpdateChecker.new([])
    end
  end

  def test_initialization_with_block
    checker = WatchcatRails::EventedFileUpdateChecker.new([]) { }
    assert_kind_of WatchcatRails::EventedFileUpdateChecker, checker
  end

  def test_updated_returns_false_initially
    checker = WatchcatRails::EventedFileUpdateChecker.new([]) { }
    sleep 0.1 # Give watchcat time to start
    assert_equal false, checker.updated?
  end

  def test_execute_calls_block
    executed = false
    checker = WatchcatRails::EventedFileUpdateChecker.new([]) { executed = true }
    checker.execute
    assert executed
  end

  def test_execute_if_updated_when_not_updated
    executed = false
    checker = WatchcatRails::EventedFileUpdateChecker.new([]) { executed = true }
    sleep 0.1 # Give watchcat time to start
    result = checker.execute_if_updated
    assert_equal false, result
    assert_equal false, executed
  end

  def test_file_change_detection
    test_file = File.join(@tmpdir, "test.txt")
    FileUtils.touch(test_file)

    executed = false
    checker = WatchcatRails::EventedFileUpdateChecker.new([test_file]) { executed = true }
    sleep 0.1 # Give watchcat time to start

    # Modify the file
    File.write(test_file, "test content")
    sleep 0.2 # Give watchcat time to detect change

    assert checker.updated?
    result = checker.execute_if_updated
    assert_equal true, result
    assert executed
  end

  def test_directory_with_extensions
    test_dir = @tmpdir
    test_file = File.join(test_dir, "test.rb")

    executed = false
    checker = WatchcatRails::EventedFileUpdateChecker.new([], test_dir => ["rb"]) { executed = true }
    sleep 0.1 # Give watchcat time to start

    # Create a Ruby file
    FileUtils.touch(test_file)
    sleep 0.2 # Give watchcat time to detect change

    assert checker.updated?
    result = checker.execute_if_updated
    assert_equal true, result
    assert executed
  end

  def test_directory_ignores_wrong_extensions
    test_dir = @tmpdir
    test_file = File.join(test_dir, "test.txt")

    checker = WatchcatRails::EventedFileUpdateChecker.new([], test_dir => ["rb"]) { }
    sleep 0.1 # Give watchcat time to start

    # Create a text file (should be ignored)
    FileUtils.touch(test_file)
    sleep 0.2 # Give watchcat time to detect change

    assert_equal false, checker.updated?
  end

  def test_updated_resets_after_execute
    test_file = File.join(@tmpdir, "test.txt")
    FileUtils.touch(test_file)

    executed = false
    checker = WatchcatRails::EventedFileUpdateChecker.new([test_file]) { executed = true }
    sleep 0.1 # Give watchcat time to start

    # Modify the file
    File.write(test_file, "test content")
    sleep 0.2 # Give watchcat time to detect change

    assert checker.updated?
    checker.execute
    assert_equal false, checker.updated?
    # Silence warning by referencing the variable
    _ = executed
  end
end
