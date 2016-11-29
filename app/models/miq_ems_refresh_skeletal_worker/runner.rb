require 'thread'

class MiqEmsRefreshSkeletalWorker::Runner < MiqWorker::Runner
  self.wait_for_worker_monitor = false

  OPTIONS_PARSER_SETTINGS = MiqWorker::Runner::OPTIONS_PARSER_SETTINGS + [
    [:ems_id, 'EMS Instance ID', String],
  ]

  def after_initialize
    @ems = ExtManagementSystem.find(@cfg[:ems_id])
    do_exit("Unable to find instance for EMS id [#{@cfg[:ems_id]}].", 1) if @ems.nil?
    do_exit("EMS id [#{@cfg[:ems_id]}] failed authentication check.", 1) unless @ems.authentication_check.first

    # Global Work Queue
    @queue = Queue.new
  end

  def do_before_work_loop
    @tid = start_updater
  end

  def log_prefix
    @log_prefix ||= "EMS [#{@ems.hostname}] as [#{@ems.authentication_userid}]"
  end

  def before_exit(message, _exit_code)
    @exit_requested = true

    unless @vim.nil?
      safe_log("#{message} Stopping thread.")
      @vim.stop rescue nil
    end

    unless @tid.nil?
      safe_log("#{message} Waiting for thread to stop.")
      @tid.join(worker_settings[:thread_shutdown_timeout] || 10.seconds) rescue nil
    end

    if @queue
      safe_log("#{message} Draining queue.")
      drain_queue rescue nil
    end
  end

  def start_updater
    @log_prefix = nil
    @exit_requested = false

    begin
      _log.info("#{log_prefix} Validating Connection/Credentials")
      @ems.verify_credentials
    rescue => err
      _log.warn("#{log_prefix} #{err.message}")
      return nil
    end

    _log.info("#{log_prefix} Starting thread")
    require 'VMwareWebService/MiqVimSkeletalUpdater'

    tid = Thread.new do
      begin
        @vim = MiqVimSkeletalUpdater.new(@ems.hostname, @ems.authentication_userid, @ems.authentication_password)
        @vim.monitorUpdates { |*u| process_update(u) }
      rescue Handsoap::Fault => err
        if  @exit_requested && (err.code == "ServerFaultCode") && (err.reason == "The task was canceled by a user.")
          _log.info("#{log_prefix} Thread terminated normally")
        else
          _log.error("#{log_prefix} Thread aborted because [#{err.message}]")
          _log.error("#{log_prefix} Error details: [#{err.details}]")
          _log.log_backtrace(err)
        end
        Thread.exit
      rescue => err
        _log.error("#{log_prefix} Thread aborted because [#{err.message}]")
        _log.log_backtrace(err) unless err.kind_of?(Errno::ECONNREFUSED)
        Thread.exit
      end
    end

    _log.info("#{log_prefix} Started thread")

    tid
  end

  def do_work
    if @tid.nil? || !@tid.alive?
      _log.info("#{log_prefix} Thread gone. Restarting...")
      @tid = start_updater
    end

    process_updates
  end

  def drain_queue
    process_update(@queue.deq) while @queue.length > 0
  end

  def process_updates
    while @queue.length > 0
      heartbeat
      process_update(@queue.deq)
      Thread.pass
    end
  end

  def process_update(update)
    kind, mor, props = update
    ems_id = @ems.id

    _log.info("#{log_prefix} Update: #{update.inspect}")

    case kind
    when 'enter', 'modify'
      target = EmsRefresh.save_new_target(:vm => {:ems_ref => mor, :ems_id => ems_id})
    when 'leave'
      # Delete the managed entity
    end
  end
end
