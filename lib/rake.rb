# FIXME Tests
require "lib/command_line"

class Rake
  include CommandLine

  def initialize(path)
    @path = path
  end

  def log_file
    @log_file ||= File.join(@path, "rake.log")
  end

  def rake(task, options = {})
    options = {:dir => @path, :stdout => log_file, :stderr => log_file}.merge(options)
    FileUtils.rm_f(log_file)
    FileUtils.mkdir_p(File.dirname(log_file))
    FileUtils.touch(log_file)
    command = []
    if File.exists?(File.join(@path, 'Gemfile'))
      command << 'bundle'
      command << 'exec'
    end
    command << 'rake'
    command << task
    execute(command, options)
  end
end
