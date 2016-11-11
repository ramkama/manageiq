
module DMiqVimSync
  #
  # This method is called - with the cacheLock held - when returning an object from the cache to the client.
  # It used to produce a full recursive copy of the object before releasing the lock.
  # When used in the broker, the DRB layer would then marshal the copy of the object to return it to the remote client.
  # This new scheme enables us to hold the cacheLock until after DRB marshals the object, eliminating the need
  # for this method to produce a full recursive copy.
  #
  # The lock count of the cacheLock is incremented, so when this method's caller releases the lock, the lock
  # will still be held. The object to be returned and the cacheLock are wraped in a MiqDrbReturn object
  # and returned to the DRB layer, which will marshal the object and release the lock. See below.
  #
  def dupObj(obj)
    return(obj) unless @cacheLock.sync_locked?
    $vim_log.debug "DMiqVim::dupObj: LOCKING [#{Thread.current.object_id}] <#{obj.object_id}>" if $vim_log.debug?
    @cacheLock.sync_lock(:SH)
    (MiqDrbReturn.new(obj, @cacheLock))
  end
end # module DMiqVimSync

class DRb::DRbMessage
  def dump_original(obj, error=false)  # :nodoc:
    obj = make_proxy(obj, error) if obj.kind_of? DRbUndumped
    begin
      str = Marshal::dump(obj)
    rescue
      str = Marshal::dump(make_proxy(obj, error))
    end

    begin
      _obj = Marshal::load(str)
    rescue
      $vim_log.warn "#{self.class.name}##{__method__}: failed to Marshal::load obj: #{obj.inspect} str: #{str.inspect}"
    end

    ret = [str.size].pack('N') + str

    $vim_log.debug "DRbMessage#dump size: #{str.size} csum: #{Digest::MD5.hexdigest(ret)}"

    if str.size > 52428800 # 50MB default load_limit
      $vim_log.warn "DRbMessage#dump message size greater than default load_limit: #{str.inspect}"
    end

    ret
  end

  #
  # This is the DRB half of the dupObj locking scheme. If we get a MiqDrbReturn object,
  # we marshal the object it wraps and release the lock.
  #
  def dump(obj, error = false)
    #
    # Place a temp hold on the object until the client registers it.
    #
    obj.holdBrokerObj if obj.respond_to?(:holdBrokerObj)

    return(dump_original(obj, error)) unless obj.kind_of?(MiqDrbReturn)
    begin
      return(dump_original(obj.obj, error))
    ensure
      if obj.lock && obj.lock.sync_locked?
        $vim_log.debug "DRb::DRbMessage.dump: UNLOCKING [#{Thread.current.object_id}] <#{obj.obj.object_id}>" if $vim_log.debug?
        obj.lock.sync_unlock
      end
    end
  end
end # class DRb::DRbMessage
