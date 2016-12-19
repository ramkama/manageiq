class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::VM
    def self.parse_vm(
      vm_inv,
      storage_inv,
      storage_uids,
      storage_profile_uids,
      host_uids,
      cluster_uids_by_host,
      lan_uids,
      guest_device_uids,
      storage_profile_by_disk_mor,
      storage_profile_by_vm_mor
    )
      mor = vm_inv['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

      summary = vm_inv["summary"]
      summary_config = summary["config"] unless summary.nil?
      pathname = summary_config["vmPathName"] unless summary_config.nil?

      config = vm_inv["config"]

      # Determine if the data from VC is valid.
      invalid, err = if summary_config.nil? || config.nil?
                       type = ['summary_config', 'config'].find_all { |t| eval(t).nil? }.join(", ")
                       [true, "Missing configuration for VM [#{mor}]: #{type}."]
                     elsif summary_config["uuid"].blank?
                       [true, "Missing UUID for VM [#{mor}]."]
                     elsif pathname.blank?
                       _log.debug "vmPathname class: [#{pathname.class}] inspect: [#{pathname.inspect}]"
                       [true, "Missing pathname location for VM [#{mor}]."]
                     else
                       false
                     end

      if invalid
        _log.warn "#{err} Skipping."

        new_result = {
          :invalid     => true,
          :ems_ref     => mor,
          :ems_ref_obj => mor
        }

        return new_result
      end

      runtime         = summary['runtime']
      template        = summary_config["template"].to_s.downcase == "true"
      raw_power_state = template ? "never" : runtime['powerState']

      begin
        storage_name, location = VmOrTemplate.repository_parse_path(pathname)
      rescue => err
        _log.warn("Warning: [#{err.message}]")
        _log.debug("Problem processing location for VM [#{summary_config["name"]}] location: [#{pathname}]")
        location = VmOrTemplate.location2uri(pathname)
      end

      affinity_set = config.fetch_path('cpuAffinity', 'affinitySet')
      # The affinity_set will be an array of integers if set
      cpu_affinity = nil
      cpu_affinity = affinity_set.kind_of?(Array) ? affinity_set.join(",") : affinity_set.to_s if affinity_set

      tools_status = summary.fetch_path('guest', 'toolsStatus')
      tools_status = nil if tools_status.blank?
      # tools_installed = case tools_status
      # when 'toolsNotRunning', 'toolsOk', 'toolsOld' then true
      # when 'toolsNotInstalled' then false
      # when nil then nil
      # else false
      # end

      boot_time = runtime['bootTime'].blank? ? nil : runtime['bootTime']

      standby_act = nil
      power_options = config["defaultPowerOps"]
      unless power_options.blank?
        standby_act = power_options["standbyAction"] if power_options["standbyAction"]
        # Other possible keys to look at:
        #   defaultPowerOffType, defaultResetType, defaultSuspendType
        #   powerOffType, resetType, suspendType
      end

      # Other items to possibly include:
      #   boot_delay = config.fetch_path("bootOptions", "bootDelay")
      #   virtual_mmu_usage = config.fetch_path("flags", "virtualMmuUsage")

      # Collect the reservation information
      resource_config = vm_inv["resourceConfig"]
      memory = resource_config && resource_config["memoryAllocation"]
      cpu    = resource_config && resource_config["cpuAllocation"]

      # Collect the storages and hardware inventory
      storages = RefreshParser.get_mors(vm_inv, 'datastore').collect { |s| storage_uids[s] }.compact
      storage  = storage_uids[normalize_vm_storage_uid(vm_inv, storage_inv)]

      host_mor = runtime['host']
      hardware = vm_inv_to_hardware_hash(vm_inv)
      hardware[:disks] = vm_inv_to_disk_hashes(vm_inv, storage_uids, storage_profile_by_disk_mor)
      hardware[:guest_devices], guest_device_uids[mor] = vm_inv_to_guest_device_hashes(vm_inv, lan_uids[host_mor])
      hardware[:networks] = vm_inv_to_network_hashes(vm_inv, guest_device_uids[mor])
      uid = hardware[:bios]

      new_result = {
        :type                  => template ? ManageIQ::Providers::Vmware::InfraManager::Template.name : ManageIQ::Providers::Vmware::InfraManager::Vm.name,
        :ems_ref               => mor,
        :ems_ref_obj           => mor,
        :uid_ems               => uid,
        :name                  => URI.decode(summary_config["name"]),
        :vendor                => "vmware",
        :raw_power_state       => raw_power_state,
        :location              => location,
        :tools_status          => tools_status,
        :boot_time             => boot_time,
        :standby_action        => standby_act,
        :connection_state      => runtime['connectionState'],
        :cpu_affinity          => cpu_affinity,
        :template              => template,
        :linked_clone          => vm_inv_to_linked_clone(vm_inv),
        :fault_tolerance       => vm_inv_to_fault_tolerance(vm_inv),

        :memory_reserve        => memory && memory["reservation"],
        :memory_reserve_expand => memory && memory["expandableReservation"].to_s.downcase == "true",
        :memory_limit          => memory && memory["limit"],
        :memory_shares         => memory && memory.fetch_path("shares", "shares"),
        :memory_shares_level   => memory && memory.fetch_path("shares", "level"),

        :cpu_reserve           => cpu && cpu["reservation"],
        :cpu_reserve_expand    => cpu && cpu["expandableReservation"].to_s.downcase == "true",
        :cpu_limit             => cpu && cpu["limit"],
        :cpu_shares            => cpu && cpu.fetch_path("shares", "shares"),
        :cpu_shares_level      => cpu && cpu.fetch_path("shares", "level"),

        :host                  => host_uids[host_mor],
        :ems_cluster           => cluster_uids_by_host[host_mor],
        :storages              => storages,
        :storage               => storage,
        :storage_profile       => storage_profile_by_vm_mor[mor],
        :operating_system      => vm_inv_to_os_hash(vm_inv),
        :hardware              => hardware,
        :custom_attributes     => vm_inv_to_custom_attribute_hashes(vm_inv),
        :snapshots             => vm_inv_to_snapshot_hashes(vm_inv),

        :cpu_hot_add_enabled      => config['cpuHotAddEnabled'],
        :cpu_hot_remove_enabled   => config['cpuHotRemoveEnabled'],
        :memory_hot_add_enabled   => config['memoryHotAddEnabled'],
        :memory_hot_add_limit     => config['hotPlugMemoryLimit'],
        :memory_hot_add_increment => config['hotPlugMemoryIncrementSize'],
      }
    end

    # The next 3 methods determine shared VMs (linked clones or fault tolerance).
    # Information found at http://www.vmdev.info/?p=546
    def self.vm_inv_to_shared(inv)
      unshared  = inv.fetch_path("summary", "storage", "unshared")
      committed = inv.fetch_path("summary", "storage", "committed")
      unshared.nil? || committed.nil? ? nil : unshared.to_i != committed.to_i
    end

    def self.vm_inv_to_linked_clone(inv)
      vm_inv_to_shared(inv) && inv.fetch_path("summary", "config", "ftInfo", "instanceUuids").to_miq_a.length <= 1
    end

    def self.vm_inv_to_fault_tolerance(inv)
      vm_inv_to_shared(inv) && inv.fetch_path("summary", "config", "ftInfo", "instanceUuids").to_miq_a.length > 1
    end

    def self.vm_inv_to_os_hash(inv)
      inv = inv.fetch_path('summary', 'config')
      return nil if inv.nil?

      result = {
        # If the data from VC is empty, default to "Other"
        :product_name => inv["guestFullName"].blank? ? "Other" : inv["guestFullName"]
      }
      result
    end

    def self.vm_inv_to_hardware_hash(inv)
      config = inv['config']
      inv = inv.fetch_path('summary', 'config')
      return nil if inv.nil?

      result = {
        # Downcase and strip off the word "guest" to match the value stored in the .vmx config file.
        :guest_os           => inv["guestId"].blank? ? "Other" : inv["guestId"].to_s.downcase.chomp("guest"),

        # If the data from VC is empty, default to "Other"
        :guest_os_full_name => inv["guestFullName"].blank? ? "Other" : inv["guestFullName"]
      }

      bios = MiqUUID.clean_guid(inv["uuid"]) || inv["uuid"]
      result[:bios] = bios unless bios.blank?

      if inv["numCpu"].present?
        result[:cpu_total_cores]      = inv["numCpu"].to_i

        # cast numCoresPerSocket to an integer so that we can check for nil and 0
        cpu_cores_per_socket          = config.try(:fetch_path, "hardware", "numCoresPerSocket").to_i
        result[:cpu_cores_per_socket] = (cpu_cores_per_socket.zero?) ? 1 : cpu_cores_per_socket
        result[:cpu_sockets]          = result[:cpu_total_cores] / result[:cpu_cores_per_socket]
      end

      result[:annotation] = inv["annotation"].present? ? inv["annotation"] : nil
      result[:memory_mb] = inv["memorySizeMB"] unless inv["memorySizeMB"].blank?
      result[:virtual_hw_version] = config['version'].to_s.split('-').last if config && config['version']

      result
    end

    def self.vm_inv_to_guest_device_hashes(inv, lan_uids)
      inv = inv.fetch_path('config', 'hardware', 'device')

      result = []
      result_uids = {}
      return result, result_uids if inv.nil?

      inv.to_miq_a.find_all { |d| d.key?('macAddress') }.each do |data|
        uid = address = data['macAddress']
        name = data.fetch_path('deviceInfo', 'label')

        backing = data['backing']
        lan_uid = case backing.xsiType
                  when "VirtualEthernetCardDistributedVirtualPortBackingInfo"
                    backing.fetch_path('port', 'portgroupKey')
                  else
                    backing['deviceName']
                  end unless backing.nil?

        lan = lan_uids[lan_uid] unless lan_uid.nil? || lan_uids.nil?

        new_result = {
          :uid_ems         => uid,
          :device_name     => name,
          :device_type     => 'ethernet',
          :controller_type => 'ethernet',
          :present         => data.fetch_path('connectable', 'connected').to_s.downcase == 'true',
          :start_connected => data.fetch_path('connectable', 'startConnected').to_s.downcase == 'true',
          :address         => address,
        }
        new_result[:lan] = lan unless lan.nil?

        result << new_result
        result_uids[uid] = new_result
      end
      return result, result_uids
    end

    def self.vm_inv_to_disk_hashes(inv, storage_uids, storage_profile_by_disk_mor = {})
      vm_mor = inv['MOR']
      inv = inv.fetch_path('config', 'hardware', 'device')

      result = []
      return result if inv.nil?

      inv = inv.to_miq_a
      inv.each do |device|
        case device.xsiType
        when 'VirtualDisk'   then device_type = 'disk'
        when 'VirtualFloppy' then device_type = 'floppy'
        when 'VirtualCdrom'  then device_type = 'cdrom'
        else next
        end

        backing = device['backing']
        device_type << (backing['fileName'].nil? ? "-raw" : "-image") if device_type == 'cdrom'

        controller = inv.detect { |d| d['key'] == device['controllerKey'] }
        controller_type = case controller.xsiType
                          when /IDE/ then 'ide'
                          when /SIO/ then 'sio'
                          else 'scsi'
                          end

        storage_mor = backing['datastore']

        new_result = {
          :device_name     => device.fetch_path('deviceInfo', 'label'),
          :device_type     => device_type,
          :controller_type => controller_type,
          :present         => true,
          :filename        => backing['fileName'] || backing['deviceName'],
          :location        => "#{controller['busNumber']}:#{device['unitNumber']}",
        }

        if device_type == 'disk'
          new_result.merge!(
            :size            => device['capacityInKB'].to_i.kilobytes,
            :mode            => backing['diskMode'],
            :storage_profile => storage_profile_by_disk_mor["#{vm_mor}:#{device['key']}"]
          )
          new_result[:disk_type] = if backing.key?('compatibilityMode')
                                     "rdm-#{backing['compatibilityMode'].to_s[0...-4]}"  # physicalMode or virtualMode
                                   else
                                     (backing['thinProvisioned'].to_s.downcase == 'true') ? 'thin' : 'thick'
                                   end
        else
          new_result[:start_connected] = device.fetch_path('connectable', 'startConnected').to_s.downcase == 'true'
        end

        new_result[:storage] = storage_uids[storage_mor] unless storage_mor.nil?

        result << new_result
      end

      result
    end

    def self.vm_inv_to_network_hashes(inv, guest_device_uids)
      inv_guest = inv.fetch_path('summary', 'guest')
      inv_net = inv.fetch_path('guest', 'net')

      result = []
      return result if inv_guest.nil? || inv_net.nil?

      hostname = inv_guest['hostName'].blank? ? nil : inv_guest['hostName']
      guest_ip = inv_guest['ipAddress'].blank? ? nil : inv_guest['ipAddress']
      return result if hostname.nil? && guest_ip.nil?

      inv_net.to_miq_a.each do |data|
        ipv4, ipv6 = data['ipAddress'].to_miq_a.compact.collect(&:to_s).sort.partition { |ip| ip =~ /([0-9]{1,3}\.){3}[0-9]{1,3}/ }
        ipv4 << nil if ipv4.empty?
        ipaddresses = ipv4.zip_stretched(ipv6)

        guest_device = guest_device_uids[data['macAddress']]

        ipaddresses.each do |ipaddress, ipv6address|
          new_result = {
            :hostname => hostname
          }
          new_result[:ipaddress] = ipaddress unless ipaddress.nil?
          new_result[:ipv6address] = ipv6address unless ipv6address.nil?

          result << new_result
          guest_device[:network] = new_result unless guest_device.nil?
        end
      end

      result
    end

    def self.vm_inv_to_custom_attribute_hashes(inv)
      custom_values = inv.fetch_path('summary', 'customValue')
      available_fields = inv['availableField']

      result = []
      return result if custom_values.nil? || available_fields.nil?

      key_to_name = {}
      available_fields.each { |af| key_to_name[af['key']] = af['name'] }
      custom_values.each do |cv|
        new_result = {
          :section => 'custom_field',
          :name    => key_to_name[cv['key']],
          :value   => cv['value'],
          :source  => "VC",
        }
        result << new_result
      end

      result
    end

    def self.vm_inv_to_snapshot_hashes(inv)
      result = []
      inv = inv['snapshot']
      return result if inv.nil? || inv['rootSnapshotList'].blank?

      # Handle rootSnapshotList being an Array of Hashes or a single Hash
      inv['rootSnapshotList'].to_miq_a.each do |snapshot|
        result += snapshot_inv_to_snapshot_hashes(snapshot, inv['currentSnapshot'])
      end
      result
    end

    def self.snapshot_inv_to_snapshot_hashes(inv, current, parent_uid = nil)
      result = []

      create_time_ems = inv['createTime']
      create_time = Time.parse(create_time_ems).getutc

      # Fix case where blank description comes back as a Hash instead
      description = inv['description']
      description = nil if description.kind_of?(Hash)

      nh = {
        :ems_ref     => inv['snapshot'],
        :ems_ref_obj => inv['snapshot'],
        :uid_ems     => create_time_ems,
        :uid         => create_time.iso8601(6),
        :parent_uid  => parent_uid,
        :name        => inv['name'],
        :description => description,
        :create_time => create_time,
        :current     => inv['snapshot'] == current,
      }

      result << nh

      inv['childSnapshotList'].to_miq_a.each do |child_snapshot_info|
        result += snapshot_inv_to_snapshot_hashes(child_snapshot_info, current, nh[:uid])
      end

      result
    end

    def self.normalize_vm_storage_uid(inv, full_storage_inv)
      vm_path_name   = inv.fetch_path('summary', 'config', 'vmPathName')
      datastore_name = vm_path_name.gsub(/^\[([^\]]*)\].*/, '\1') if vm_path_name

      inv['datastore'].to_miq_a.detect do |mor|
        full_storage_inv.fetch_path(mor, 'summary', 'name') == datastore_name
      end
    end
  end
end
