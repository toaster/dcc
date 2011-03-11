require 'politics'
require 'politics/static_queue_worker'
require 'app/models/project'
require 'app/models/build'
require 'app/models/bucket'
require 'app/models/log'
require 'lib/rake'
require 'lib/mailer'
require 'lib/bucket_store'
require 'monitor'
require 'set'
require 'iconv'

class DCCWorker
  include Politics::StaticQueueWorker
  include MonitorMixin

  attr_reader :admin_e_mail_address

  def initialize(group_name, memcached_servers, options = {})
    super()
    options = {:log_level => Logger::WARN, :servers => memcached_servers}.merge(options)
    log.level = options[:log_level]
    log.formatter = Logger::Formatter.new()
    DCC::Logger.setLog(log)
    register_worker group_name, 0, options
    @buckets = BucketStore.new
    @admin_e_mail_address = options[:admin_e_mail_address]
    @succeeded_before_all_tasks = []
    @prepared_bucket_groups = Set.new
    @currently_processed_bucket_id = nil
    if options[:tyrant]
      log.debug { "become tyrant for at least #{1000000000} seconds" }
      instance_eval do
        alias :original_seize_leadership :seize_leadership
        def seize_leadership
          original_seize_leadership(1000000000)
        end
      end
      seize_leadership
    end
  end

  def run
    log.debug "running"
    log_general_error_on_failure("running worker failed") do
      process_bucket do |bucket_id|
        @currently_processed_bucket_id = bucket_id
        bucket = retry_on_mysql_failure {Bucket.find(bucket_id)}
        log_bucket_error_on_failure(bucket, "processing bucket failed") do
          perform_task bucket
        end
      end
    end
  end

  def perform_task(bucket)
    log.debug "performing task #{bucket}"
    logs = bucket.logs
    build = bucket.build
    project = build.project
    git = project.git
    git.update :commit => build.commit

    bucket_group = project.bucket_group(bucket.name)
    @prepared_bucket_groups.clear if @last_handled_build != build.id
    unless @prepared_bucket_groups.include?(bucket_group)
      project.before_each_bucket_group_code.call if project.before_each_bucket_group_code
      @prepared_bucket_groups.add(bucket_group)
    end

    succeeded = true
    @succeeded_before_all_tasks = [] if @last_handled_build != build.id
    before_all_tasks = project.before_all_tasks(bucket.name) - @succeeded_before_all_tasks
    if !before_all_tasks.empty?
      succeeded = perform_rake_tasks(git.path, before_all_tasks, logs)
      @succeeded_before_all_tasks += succeeded ? before_all_tasks : []
      @last_handled_build = build.id
    end
    if succeeded
      succeeded &&= perform_rake_tasks(git.path, project.before_bucket_tasks(bucket.name), logs)
      succeeded &&= perform_rake_tasks(git.path, project.bucket_tasks(bucket.name), logs)
      succeeded = perform_rake_tasks(git.path, project.after_bucket_tasks(bucket.name), logs) &&
          succeeded
    end
    whole_log = ''
    logs.each do |log|
      whole_log << log.log
    end
    bucket.log = whole_log
    bucket.status = succeeded ? 10 : 40
    bucket.finished_at = Time.now
    bucket.save
    logs.clear
    if !succeeded
      bucket.build_error_log
      Mailer.deliver_failure_message(bucket, uri)
    else
      last_build = project.last_build(:before_build => build)
      if last_build && (last_bucket = last_build.buckets.find_by_name(bucket.name)) &&
            last_bucket.status != 10
        Mailer.deliver_fixed_message(bucket, uri)
      end
    end
  end

  def perform_rake_task(path, task, logs)
    process_state = _perform_rake_task(path, task, logs)
    log.debug "process terminated? #{process_state.exited?} with status #{process_state.inspect}"
    if (process_state.signaled? && process_state.termsig == 6)
      log.debug "rake aborted - retry it once"
      logs.create(:log => "\n\n#{"-" * 80}\n\nrake aborted - retry it once\n\n#{"-" * 80}\n\n")
      process_state = _perform_rake_task(path, task, logs)
      log.debug "process terminated? #{process_state.exited?} with status #{process_state.inspect}"
    end
    process_state.exitstatus == 0
  end

  def _perform_rake_task(path, task, logs)
    log.debug "performing rake task #{task}"
    rake = Rake.new(path)
    old_connections = ActiveRecord::Base.connection_pool
    old_connections.disconnect!
    pid = fork do
      ActiveRecord::Base.establish_connection(old_connections.spec.config)
      begin
        rake.rake(task)
      rescue
        exit 1
      end
      exit 0
    end
    ActiveRecord::Base.establish_connection(old_connections.spec.config)
    log_length = 0
    while !Process.waitpid(pid, Process::WNOHANG)
      log_length += read_log_into_db(rake.log_file, log_length, logs)
      sleep log_polling_intervall
    end
    read_log_into_db(rake.log_file, log_length, logs)
    $?
  end

  def read_log_into_db(log_file, log_length, logs)
    log.debug "read #{log_file} from position #{log_length} into DB"
    log_content = ""
    begin
      log_content = Iconv.new('UTF-8//IGNORE', 'UTF-8').
          iconv(/.*/um.match(File.open(log_file) {|f| f.seek(log_length) and f.read})[0])
      log.debug "read log (length: #{log_content.length}): #{log_content}"
    rescue Exception => e
      log.debug "could not read #{log_file}: #{e}"
    end
    if !log_content.empty?
      logs.create(:log => log_content)
      log_content.length
    else
      0
    end
  end

  def log_polling_intervall
    return 10
  end

  def initialize_buckets
    log.debug "initializing buckets"
    update_buckets
  end

  def update_buckets
    log.debug "updating buckets"
    Project.find(:all).each do |project|
      if !project_in_build?(project)
        compute_buckets_and_finish_last_build_if_necessary(project)
      end
    end
  end

  def project_in_build?(project)
    !@buckets.empty?(project.name) || (
      build = project.last_build
      build && !build.buckets.select do |b|
        (b.status == 30 && (DRbObject.new(nil, b.worker_uri).processing?(b.id) rescue false)) ||
        (
          (b.status == 20 || b.status == 30) && (
            log.debug "setting bucket #{b} to „processing failed“: status = #{b.status}, " +
                "answer from worker (#{b.worker_uri}): #{
                  begin
                    DRbObject.new(nil, b.worker_uri).processing?(b.id)
                  rescue Exception => e
                    "failure: #{e.message}\n\n#{e.backtrace.join("\n")}"
                  end
                }"
            b.status = 35
            b.save
            false
          )
        )
      end.empty?
    )
  end

  def processing?(bucket_id)
    log.debug "answering on processing?(#{bucket_id}): #{
        @currently_processed_bucket_id == bucket_id} for #{@currently_processed_bucket_id}"
    @currently_processed_bucket_id == bucket_id
  end

  def read_buckets(project)
    buckets = []
    log.debug "reading buckets for project #{project}"
    log_project_error_on_failure(project, "reading buckets failed") do
      if project.wants_build?
        build_number = project.next_build_number
        build = project.builds.create(:commit => project.current_commit,
            :build_number => build_number, :leader_uri => uri)
        project.buckets_tasks.each_key do |task|
          bucket = build.buckets.create(:name => task, :status => 20)
          buckets << bucket.id
        end
        project.update_state
      end
      project.last_system_error = nil
      project.save
    end
    log.debug "read buckets #{buckets.inspect}"
    buckets
  end

  def next_bucket(requestor_uri)
    sleep(rand(21) / 10.0)
    bucket_spec = [@buckets.next_bucket(requestor_uri), sleep_until_next_bucket_time]
    if bucket_id = bucket_spec[0]
      bucket = Bucket.find(bucket_id)
      bucket.worker_uri = requestor_uri
      bucket.status = 30
      bucket.started_at = Time.now
      bucket.save
      log.debug "deliver bucket #{bucket} to #{requestor_uri}"
      unless (build = bucket.build).started_at
        build.started_at = Time.now
        build.save
      end
    end
    bucket_spec
  end

  def log_bucket_error_on_failure(bucket, subject, &block)
    log_error_on_failure(subject, :bucket => bucket, &block)
  end

  def log_project_error_on_failure(project, subject, &block)
    log_error_on_failure(subject, :project => project, &block)
  end

  def log_general_error_on_failure(subject, &block)
    log_error_on_failure(subject, :email_address => admin_e_mail_address, &block)
  end

private

  def retry_on_mysql_failure
    yield
  rescue ActiveRecord::StatementInvalid => e
    if e.message =~ /MySQL server has gone away/
      log.debug "MySQL server has gone away … retry with new connection"
      ActiveRecord::Base.establish_connection(ActiveRecord::Base.connection_pool.spec.config)
      sleep 3
      result = yield
      log.debug "retry with new connection succeeded"
      result
    else
      log.debug "ActiveRecord::StatementInvalid occurred #{e.message}"
      raise e
    end
  end

  @@pbl = 0
  def log_error_on_failure(subject, options = {})
    log.debug "entering protected block (->#{@@pbl += 1})"
    begin
      retry_on_mysql_failure do
        retry_on_mysql_failure do
          yield
        end
      end
    rescue ActiveRecord::StatementInvalid => e
      log.debug "retrying with new MySQL connection failed for three times"
      raise e
    end
    log.debug "leaving protected block (->#{@@pbl -= 1})"
  rescue Exception => e
    log.debug "error #{e.class} occurred in protected block (->#{@@pbl -= 1})"
    msg = "uri: #{uri}\nleader_uri: #{leader_uri}\n\n#{e.message}\n\n#{e.backtrace.join("\n")}"
    log.error "#{subject}\n#{msg}"
    if bucket = options[:bucket]
      bucket.status = 35
      bucket.log = "#{bucket.log}\n\n------ Processing failed ------\n\n#{subject}\n\n#{msg}"
      bucket.save
    elsif project = options[:project]
      project.last_system_error = "#{subject}\n\n#{msg}"
      project.save
    end
    if options[:email_address]
      Mailer.deliver_message options[:email_address], subject, msg
    end
  end

  def perform_rake_tasks(path, tasks, logs)
    succeeded = true
    log.debug "performing rake tasks #{tasks}"
    tasks.each {|task| succeeded = perform_rake_task(path, task, logs) && succeeded}
    succeeded
  end

  def compute_buckets_and_finish_last_build_if_necessary(project)
    build = project.last_build
    log.debug "finished?: checking build #{build || '<nil>'} (#{
        build && build.finished_at || '<nil>'})"
    if build && !build.finished_at
      log.debug "marking project #{project.name}'s build #{build.identifier} as finished"
      build.finished_at = Time.now
      build.save
    end
    buckets = read_buckets(project)
    synchronize do
      @buckets.set_buckets project.name, buckets
    end
  end
end
