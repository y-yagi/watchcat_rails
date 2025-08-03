# frozen_string_literal: true

require "pathname"
require "concurrent/atomic/atomic_boolean"
require "active_support/fork_tracker"
require "watchcat"

module WatchcatRails
  class EventedFileUpdateChecker
    def initialize(files, dirs = {}, &block)
      unless block
        raise ArgumentError, "A block is required to initialize an EventedFileUpdateChecker"
      end

      @block = block
      @core = Core.new(files, dirs)
      ObjectSpace.define_finalizer(self, @core.finalizer)
    end

    def inspect
      "#<WatchcatRails::EventedFileUpdateChecker:#{object_id} @files=#{@core.files.to_a.inspect}"
    end

    def updated?
      if @core.restart?
        @core.thread_safely(&:restart)
        @core.updated.make_true
      end

      @core.updated.true?
    end

    def execute
      @core.updated.make_false
      @block.call
    end

    def execute_if_updated
      if updated?
        yield if block_given?
        execute
        true
      else
        false
      end
    end

    class Core
      attr_reader :updated, :files

      def initialize(files, dirs)
        gem_paths = Gem.path
        files = files.map { |f| Pathname(f).expand_path }
        files.reject! { |f| f.to_s.start_with?(*gem_paths) }
        @files = files.to_set

        @dirs = dirs.each_with_object({}) do |(dir, exts), hash|
          next if dir.start_with?(*gem_paths)
          hash[Pathname(dir).expand_path] = Array(exts).map { |ext| ext.to_s.sub(/\A\.?/, ".") }.to_set
        end

        @common_path = common_path(@dirs.keys)

        @dtw = directories_to_watch
        @missing = []

        @updated = Concurrent::AtomicBoolean.new(false)
        @mutex = Mutex.new

        start
        @after_fork = ActiveSupport::ForkTracker.after_fork { start }
      end

      def finalizer
        proc do
          stop
          ActiveSupport::ForkTracker.unregister(@after_fork) if @after_fork
        end
      end

      def thread_safely
        @mutex.synchronize do
          yield self
        end
      end

      def start
        normalize_dirs!
        @dtw, @missing = [*@dtw, *@missing].partition(&:exist?)
        @watcher = @dtw.any? ? start_watcher : nil
      end

      def stop
        @watcher&.stop
      end

      def restart
        stop
        start
      end

      def restart?
        @missing.any?(&:exist?)
      end

      def normalize_dirs!
        @dirs.transform_keys! do |dir|
          dir.exist? ? dir.realpath : dir
        end
      end

      def changed(event)
        unless @updated.true?
          @updated.make_true if event.paths.any? { |f| watching?(f) }
        end
      end

      def watching?(file)
        file = Pathname(file)

        if @files.member?(file)
          true
        elsif file.directory?
          false
        else
          ext = file.extname

          file.dirname.ascend do |dir|
            matching = @dirs[dir]

            if matching && (matching.empty? || matching.include?(ext))
              break true
            elsif dir == @common_path || dir.root?
              break false
            end
          end
        end
      end

      def directories_to_watch
        dtw = @dirs.keys | @files.map(&:dirname)
        accounted_for = dtw.to_set + Gem.path.map { |path| Pathname(path) }
        dtw.reject { |dir| dir.ascend.drop(1).any? { |parent| accounted_for.include?(parent) } }
      end

      def common_path(paths)
        paths.map { |path| path.ascend.to_a }.reduce(&:&)&.first
      end

      private

      def start_watcher
        return nil if @dtw.empty?

        paths_to_watch = @dtw.map(&:to_s)

        # Filter out paths that might cause permission errors
        accessible_paths = paths_to_watch.select do |path|
          begin
            File.readable?(path) && Dir.exist?(path)
          rescue
            false
          end
        end

        return nil if accessible_paths.empty?

        begin
          Watchcat.watch(accessible_paths, recursive: true) do |event|
            changed(event)
          end
        rescue
          # If watchcat fails to start (e.g., permission denied), return nil
          # This allows the checker to continue working in polling mode
          nil
        end
      end
    end
  end
end
