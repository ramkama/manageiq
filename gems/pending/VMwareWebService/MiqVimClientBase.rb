require 'pathname'

require 'sync'
require 'VMwareWebService/VimService'

# require 'profile'

class MiqVimClientBase < VimService
  @@receiveTimeout = 120

  attr_reader :server, :username, :password, :connId

  def initialize(server, username, password)
    @server   = server
    @username = username
    @password = password
    @connId   = "#{@server}_#{@username}"

    @receiveTimeout = @@receiveTimeout

    super(server)

    @connected  = false
    @connLock = Sync.new
  end

  def self.receiveTimeout=(val)
    @@receiveTimeout = val
  end

  def self.receiveTimeout
    @@receiveTimeout
  end

  def receiveTimeout=(val)
    @connLock.synchronize(:EX) do
      @receiveTimeout = val
      http_client.receive_timeout = @receiveTimeout if http_client
    end
  end

  def receiveTimeout
    @connLock.synchronize(:SH) do
      @receiveTimeout
    end
  end

  def connect
    $vim_log.debug "#{self.class.name}.connect(#{@connId}): #{$PROGRAM_NAME} #{ARGV.join(' ')}" if $vim_log.debug?
    @connLock.synchronize(:EX) do
      return if @connected

      login_args = {
        :userName => @username,
        :password => @password
      }

      @vim.serviceContent.sessionManager.Login login_args
      @connected = true
    end
  end

  def disconnect
    $vim_log.debug "#{self.class.name}.disconnect(#{@connId}): #{$PROGRAM_NAME} #{ARGV.join(' ')}" if $vim_log.debug?
    @connLock.synchronize(:EX) do
      return unless @connected
      @vim.close
      @connected = false
    end
  end

  def currentServerTime
    DateTime.parse(currentTime)
  end

  def acquireCloneTicket
    super(@sic.sessionManager)
  end

  def verify_callback(is_ok, ctx)
    if $DEBUG
      puts "#{is_ok ? 'ok' : 'ng'}: #{ctx.current_cert.subject}"
    end
    unless is_ok
      depth = ctx.error_depth
      code = ctx.error
      msg = ctx.error_string
      STDERR.puts "at depth #{depth} - #{code}: #{msg}" if $DEBUG
    end
    is_ok
  end
end # class MiqVimClientBase
