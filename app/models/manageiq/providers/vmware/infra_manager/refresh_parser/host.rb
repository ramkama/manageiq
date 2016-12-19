class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::Host
    def self.parse_host(
      host_inv,
      ems_inv,
      storage_uids,
      cluster_uids,
      cluster_uids_by_host,
      lan_uids,
      switch_uids,
      guest_device_uids,
      scsi_lun_uids,
      dvswitch_by_host,
      dvportgroup_by_host,
      dvswitch_uid_ems,
      dvportgroup_uid_ems
    )
      mor = host_inv['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

      config = host_inv["config"]
      dns_config = config.fetch_path('network', 'dnsConfig') unless config.nil?
      hostname = dns_config["hostName"] unless dns_config.nil?
      domain_name = dns_config["domainName"] unless dns_config.nil?

      summary = host_inv["summary"]
      product = summary.fetch_path('config', 'product') unless summary.nil?

      # Check connection state and log potential issues
      connection_state = summary.fetch_path("runtime", "connectionState") unless summary.nil?
      maintenance_mode = summary.fetch_path("runtime", "inMaintenanceMode") unless summary.nil?
      if ['disconnected', 'notResponding', nil, ''].include?(connection_state)
        _log.warn "Host [#{mor}] connection state is [#{connection_state.inspect}].  Inventory data may be missing."
      end

      # Determine if the data from VC is valid.
      invalid, err = if config.nil? || product.nil? || summary.nil?
                       type = ['config', 'product', 'summary'].find_all { |t| eval(t).nil? }.join(", ")
                       [true, "Missing configuration for Host [#{mor}]: [#{type}]."]
                     elsif hostname.blank?
                       [true, "Missing hostname information for Host [#{mor}]: dnsConfig: #{dns_config.inspect}."]
                     elsif domain_name.blank?
                       # Use the name or the summary-config-name as the hostname if either appears to be a FQDN
                       fqdn = host_inv["name"]
                       fqdn = summary.fetch_path('config', 'name') unless fqdn =~ /^#{hostname}\./
                       hostname = fqdn if fqdn =~ /^#{hostname}\./
                       false
                     else
                       hostname = "#{hostname}.#{domain_name}"
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

      # Remove the domain suffix if it is included in the hostname
      hostname = hostname.split(',').first
      # Get the IP address
      ipaddress = host_inv_to_ip(host_inv, hostname) || hostname

      vendor = product["vendor"].split(",").first.to_s.downcase
      vendor = "unknown" unless Host::VENDOR_TYPES.include?(vendor)

      product_name = product["name"].nil? ? nil : product["name"].to_s.gsub(/^VMware\s*/i, "")

      # Collect the hardware, networking, and scsi inventories
      switches, switch_uids[mor] = host_inv_to_switch_hashes(host_inv, dvswitch_by_host[mor], dvswitch_uid_ems)
      _lans, lan_uids[mor] = host_inv_to_lan_hashes(
        host_inv,
        switch_uids[mor],
        dvportgroup_by_host[mor],
        dvportgroup_uid_ems
      )

      hardware = host_inv_to_hardware_hash(host_inv)
      hardware[:guest_devices], guest_device_uids[mor] = host_inv_to_guest_device_hashes(host_inv, switch_uids[mor])
      hardware[:networks] = host_inv_to_network_hashes(host_inv, guest_device_uids[mor])

      _scsi_luns, scsi_lun_uids[mor] = host_inv_to_scsi_lun_hashes(host_inv)
      _scsi_targets = host_inv_to_scsi_target_hashes(host_inv, guest_device_uids[mor][:storage], scsi_lun_uids[mor])

      # Collect the resource pools inventory
      parent_type, parent_mor, parent_data = host_parent_resource(mor, ems_inv)
      if parent_type == :host_res
        rp_uids = RefreshParser.get_mors(parent_data, "resourcePool")
        cluster_uids_by_host[mor] = nil
      else
        rp_uids = []
        cluster_uids_by_host[mor] = cluster_uids[parent_mor]
      end

      # Collect failover host information if in a cluster
      failover = nil
      if parent_type == :cluster
        failover_hosts = parent_data.fetch_path("configuration", "dasConfig", "admissionControlPolicy", "failoverHosts")
        failover = failover_hosts && failover_hosts.include?(mor)
      end

      # Link up the storages
      storages = RefreshParser.get_mors(host_inv, 'datastore').collect { |s| storage_uids[s] }.compact

      # Find the host->storage mount info
      host_storages = host_inv_to_host_storages_hashes(host_inv, ems_inv[:storage], storage_uids)

      # Store the host 'name' value as uid_ems to use as the lookup value with MiqVim
      uid_ems = summary.nil? ? nil : summary.fetch_path('config', 'name')

      # Get other information
      asset_tag = service_tag = nil
      host_inv.fetch_path("hardware", "systemInfo", "otherIdentifyingInfo").to_miq_a.each do |info|
        next unless info.kind_of?(Hash)

        value = info["identifierValue"].to_s.strip
        value = nil if value.blank?

        case info.fetch_path("identifierType", "key")
        when "AssetTag"   then asset_tag   = value
        when "ServiceTag" then service_tag = value
        end
      end

      new_result = {
        :type             => %w(esx esxi).include?(product_name.to_s.downcase) ? "ManageIQ::Providers::Vmware::InfraManager::HostEsx" : "ManageIQ::Providers::Vmware::InfraManager::Host",
        :ems_ref          => mor,
        :ems_ref_obj      => mor,
        :name             => hostname,
        :hostname         => hostname,
        :ipaddress        => ipaddress,
        :uid_ems          => uid_ems,
        :vmm_vendor       => vendor,
        :vmm_version      => product["version"],
        :vmm_product      => product_name,
        :vmm_buildnumber  => product["build"],
        :connection_state => connection_state,
        :power_state      => connection_state != "connected" ? "off" : (maintenance_mode.to_s.downcase == "true" ? "maintenance" : "on"),
        :admin_disabled   => config["adminDisabled"].to_s.downcase == "true",
        :maintenance      => maintenance_mode.to_s.downcase == "true",
        :asset_tag        => asset_tag,
        :service_tag      => service_tag,
        :failover         => failover,
        :hyperthreading   => config.fetch_path("hyperThread", "active").to_s.downcase == "true",

        :ems_cluster      => cluster_uids_by_host[mor],
        :operating_system => host_inv_to_os_hash(host_inv, hostname),
        :system_services  => host_inv_to_system_service_hashes(host_inv),

        :hardware         => hardware,
        :switches         => switches,
        :storages         => storages,
        :host_storages    => host_storages,

        :child_uids       => rp_uids,
      }
    end

    def self.host_inv_to_ip(inv, hostname = nil)
      _log.debug("IP lookup for host in VIM inventory data...")
      ipaddress = nil

      default_gw = inv.fetch_path("config", "network", "ipRouteConfig", "defaultGateway")
      unless default_gw.blank?
        require 'ipaddr'
        default_gw = IPAddr.new(default_gw)

        network = inv.fetch_path("config", "network")
        vnics   = network['consoleVnic'].to_miq_a + network['vnic'].to_miq_a

        vnics.each do |vnic|
          ip = vnic.fetch_path("spec", "ip", "ipAddress")
          subnet_mask = vnic.fetch_path("spec", "ip", "subnetMask")
          next if ip.blank? || subnet_mask.blank?

          if default_gw.mask(subnet_mask).include?(ip)
            ipaddress = ip
            _log.debug("IP lookup for host in VIM inventory data...Complete: IP found: [#{ipaddress}]")
            break
          end
        end
      end

      if ipaddress.nil?
        warn_msg = "IP lookup for host in VIM inventory data...Failed."
        if [nil, "localhost", "localhost.localdomain", "127.0.0.1"].include?(hostname)
          _log.warn warn_msg
        else
          _log.warn "#{warn_msg} Falling back to reverse lookup."
          begin
            # IPSocket.getaddress(hostname) is not used because it was appending
            #   a ".com" to the "esxdev001.localdomain" which resolved to a real
            #   internet address. Socket.getaddrinfo does the right thing.
            # TODO: Can this moved to MiqSockUtil?

            _log.debug "IP lookup by hostname [#{hostname}]..."
            ipaddress = Socket.getaddrinfo(hostname, nil)[0][3]
            _log.debug "IP lookup by hostname [#{hostname}]...Complete: IP found: [#{ipaddress}]"
          rescue => err
            _log.warn "IP lookup by hostname [#{hostname}]...Failed with the following error: #{err}"
          end
        end
      end

      ipaddress
    end

    def self.host_inv_to_os_hash(inv, hostname)
      inv = inv.fetch_path('summary', 'config', 'product')
      return nil if inv.nil?

      result = {:name => hostname}
      result[:product_name] = inv["name"].gsub(/^VMware\s*/i, "") unless inv["name"].blank?
      result[:version] = inv["version"] unless inv["version"].blank?
      result[:build_number] = inv["build"] unless inv["build"].blank?
      result[:product_type] = inv["osType"] unless inv["osType"].blank?
      result
    end

    def self.host_inv_to_hardware_hash(inv)
      console = inv.fetch_path('config', 'consoleReservation')
      inv = inv['summary']
      return nil if inv.nil?

      result = {}

      hdw = inv["hardware"]
      unless hdw.blank?
        result[:cpu_speed] = hdw["cpuMhz"] unless hdw["cpuMhz"].blank?
        result[:cpu_type] = hdw["cpuModel"] unless hdw["cpuModel"].blank?
        result[:manufacturer] = hdw["vendor"] unless hdw["vendor"].blank?
        result[:model] = hdw["model"] unless hdw["model"].blank?
        result[:number_of_nics] = hdw["numNics"] unless hdw["numNics"].blank?

        # Value provided by VC is in bytes, need to convert to MB
        result[:memory_mb] = is_numeric?(hdw["memorySize"]) ? (hdw["memorySize"].to_f / 1.megabyte).round : nil
        unless console.nil?
          result[:memory_console] = is_numeric?(console["serviceConsoleReserved"]) ? (console["serviceConsoleReserved"].to_f / 1048576).round : nil
        end

        result[:cpu_sockets]     = hdw["numCpuPkgs"] unless hdw["numCpuPkgs"].blank?
        result[:cpu_total_cores] = hdw["numCpuCores"] unless hdw["numCpuCores"].blank?
        # Calculate the number of cores per socket by dividing total numCpuCores by numCpuPkgs
        result[:cpu_cores_per_socket] = (result[:cpu_total_cores].to_f / result[:cpu_sockets].to_f).to_i unless hdw["numCpuCores"].blank? || hdw["numCpuPkgs"].blank?
      end

      config = inv["config"]
      unless config.blank?
        value = config.fetch_path("product", "name")
        unless value.blank?
          value = value.to_s.gsub(/^VMware\s*/i, "")
          result[:guest_os] = value
          result[:guest_os_full_name] = value
        end

        result[:vmotion_enabled] = config["vmotionEnabled"].to_s.downcase == "true" unless config["vmotionEnabled"].blank?
      end

      quickStats = inv["quickStats"]
      unless quickStats.blank?
        result[:cpu_usage] = quickStats["overallCpuUsage"] unless quickStats["overallCpuUsage"].blank?
        result[:memory_usage] = quickStats["overallMemoryUsage"] unless quickStats["overallMemoryUsage"].blank?
      end

      result
    end

    def self.host_inv_to_switch_hashes(inv, dvswitch_inv, dvswitch_uid_ems)
      inv = inv.fetch_path('config', 'network')

      result = []
      result_uids = {:pnic_id => {}}
      return result, result_uids if inv.nil?

      inv['vswitch'].to_miq_a.each do |data|
        name = uid = data['name']
        pnics = data['pnic'].to_miq_a

        security_policy = data.fetch_path('spec', 'policy', 'security') || {}

        new_result = {
          :uid_ems           => uid,
          :name              => name,
          :ports             => data['numPorts'],

          :allow_promiscuous => security_policy['allowPromiscuous'].nil? ? nil : security_policy['allowPromiscuous'].to_s.downcase == 'true',
          :forged_transmits  => security_policy['forgedTransmits'].nil? ? nil : security_policy['forgedTransmits'].to_s.downcase == 'true',
          :mac_changes       => security_policy['macChanges'].nil? ? nil : security_policy['macChanges'].to_s.downcase == 'true',

          :lans              => []
        }

        result << new_result
        result_uids[uid] = new_result

        pnics.each { |pnic| result_uids[:pnic_id][pnic] = new_result unless pnic.blank? }
      end

      dvswitch_inv.to_miq_a.each do |data|
        config = data.fetch('config', {})
        uid = data['MOR']
        security_policy   = config.fetch('defaultPortConfig', {}).fetch('securityPolicy', {})
        allow_promiscuous = security_policy.fetch_path('allowPromiscuous', 'value')
        forged_transmits  = security_policy.fetch_path('forgedTransmits', 'value')
        mac_changes       = security_policy.fetch_path('macChanges', 'value')

        dvswitch_uid_ems[uid] || dvswitch_uid_ems[uid] = {
          :uid_ems           => uid,
          :name              => config['name'] || data.fetch_path('summary', 'name'),
          :ports             => config['numPorts'] || 0,

          :allow_promiscuous => allow_promiscuous.nil? ? nil : allow_promiscuous.to_s.casecmp('true') == 0,
          :forged_transmits  => forged_transmits.nil? ? nil : forged_transmits.to_s.casecmp('true') == 0,
          :mac_changes       => mac_changes.nil? ? nil : mac_changes.to_s.casecmp('true') == 0,

          :lans              => [],
          :switch_uuid       => config['uuid'] || data.fetch_path('summary', 'uuid'),
          :shared            => true
        }

        result << dvswitch_uid_ems[uid]
        result_uids[uid] = dvswitch_uid_ems[uid]
      end
      return result, result_uids
    end

    def self.host_inv_to_lan_hashes(inv, switch_uids, dvportgroup_inv, dvportgroup_uid_ems)
      inv = inv.fetch_path('config', 'network')

      result = []
      result_uids = {}
      return result, result_uids if inv.nil?

      inv['portgroup'].to_miq_a.each do |data|
        spec = data['spec']
        next if spec.nil?

        # Find the switch to which this lan is connected
        switch = switch_uids[spec['vswitchName']]
        next if switch.nil?

        name = uid = spec['name']

        security_policy = data.fetch_path('spec', 'policy', 'security') || {}
        computed_security_policy = data.fetch_path('computedPolicy', 'security') || {}

        new_result = {
          :uid_ems                    => uid,
          :name                       => name,
          :tag                        => spec['vlanId'].to_s,

          :allow_promiscuous          => security_policy['allowPromiscuous'].nil? ? nil : security_policy['allowPromiscuous'].to_s.downcase == 'true',
          :forged_transmits           => security_policy['forgedTransmits'].nil? ? nil : security_policy['forgedTransmits'].to_s.downcase == 'true',
          :mac_changes                => security_policy['macChanges'].nil? ? nil : security_policy['macChanges'].to_s.downcase == 'true',

          :computed_allow_promiscuous => computed_security_policy['allowPromiscuous'].nil? ? nil : computed_security_policy['allowPromiscuous'].to_s.downcase == 'true',
          :computed_forged_transmits  => computed_security_policy['forgedTransmits'].nil? ? nil : computed_security_policy['forgedTransmits'].to_s.downcase == 'true',
          :computed_mac_changes       => computed_security_policy['macChanges'].nil? ? nil : computed_security_policy['macChanges'].to_s.downcase == 'true',
        }
        result << new_result
        result_uids[uid] = new_result
        switch[:lans] << new_result
      end

      dvportgroup_inv.to_miq_a.each do |data|
        spec = data['config']
        next if spec.nil?

        # Find the switch to which this lan is connected
        switch = switch_uids[spec['distributedVirtualSwitch']]
        next if switch.nil?

        uid = data['MOR']
        security_policy = spec.fetch_path('defaultPortConfig', 'securityPolicy') || {}

        unless dvportgroup_uid_ems.key?(uid)
          dvportgroup_uid_ems[uid] = {
            :uid_ems           => uid,
            :name              => spec['name'],
            :tag               => spec.fetch_path('defaultPortConfig', 'vlan', 'vlanId').to_s,

            :allow_promiscuous => security_policy.fetch_path('allowPromiscuous', 'value').to_s.casecmp('true') == 0,
            :forged_transmits  => security_policy.fetch_path('forgedTransmits', 'value').to_s.casecmp('true') == 0,
            :mac_changes       => security_policy.fetch_path('macChanges', 'value').to_s.casecmp('true') == 0,
          }
          switch[:lans] << dvportgroup_uid_ems[uid]
        end
        result << dvportgroup_uid_ems[uid]
        result_uids[uid] = dvportgroup_uid_ems[uid]
      end

      return result, result_uids
    end

    def self.host_inv_to_guest_device_hashes(inv, switch_uids)
      inv = inv['config']

      result = []
      result_uids = {}
      return result, result_uids if inv.nil?

      network = inv["network"]
      storage = inv["storageDevice"]
      return result, result_uids if network.nil? && storage.nil?

      result_uids[:pnic] = {}
      unless network.nil?
        network['pnic'].to_miq_a.each do |data|
          # Find the switch to which this pnic is connected
          switch = switch_uids[:pnic_id][data['key']]

          name = uid = data['device']

          new_result = {
            :uid_ems         => uid,
            :device_name     => name,
            :device_type     => 'ethernet',
            :location        => data['pci'],
            :present         => true,
            :controller_type => 'ethernet',
            :address         => data['mac']
          }
          new_result[:switch] = switch unless switch.nil?

          result << new_result
          result_uids[:pnic][uid] = new_result
        end
      end

      result_uids[:storage] = {:adapter_id => {}}
      unless storage.nil?
        storage['hostBusAdapter'].to_miq_a.each do |data|
          name = uid = data['device']
          adapter = data['key']
          chap_auth_enabled = data.fetch_path('authenticationProperties', 'chapAuthEnabled')

          new_result = {
            :uid_ems           => uid,
            :device_name       => name,
            :device_type       => 'storage',
            :present           => true,

            :iscsi_name        => data['iScsiName'].blank? ? nil : data['iScsiName'],
            :iscsi_alias       => data['iScsiAlias'].blank? ? nil : data['iScsiAlias'],
            :location          => data['pci'].blank? ? nil : data['pci'],
            :model             => data['model'].blank? ? nil : data['model'],

            :chap_auth_enabled => chap_auth_enabled.blank? ? nil : chap_auth_enabled.to_s.downcase == "true"
          }

          new_result[:controller_type] = case data.xsiType.to_s.split("::").last
                                         when 'HostBlockHba'        then 'Block'
                                         when 'HostFibreChannelHba' then 'Fibre'
                                         when 'HostInternetScsiHba' then 'iSCSI'
                                         when 'HostParallelScsiHba' then 'SCSI'
                                         when 'HostBusAdapter'      then 'HBA'
                                         end

          result << new_result
          result_uids[:storage][uid] = new_result
          result_uids[:storage][:adapter_id][adapter] = new_result
        end
      end

      return result, result_uids
    end

    def self.host_inv_to_network_hashes(inv, guest_device_uids)
      inv = inv.fetch_path('config', 'network')
      result = []
      return result if inv.nil?

      vnics = inv['consoleVnic'].to_miq_a + inv['vnic'].to_miq_a
      vnics.to_miq_a.each do |vnic|
        # Find the pnic to which this service console is connected
        port_key = vnic['port']
        portgroup = inv['portgroup'].to_miq_a.find { |pg| pg['port'].to_miq_a.find { |p| p['key'] == port_key } }
        next if portgroup.nil?

        vswitch_key = portgroup['vswitch']
        vswitch = inv['vswitch'].to_miq_a.find { |v| v['key'] == vswitch_key }
        next if vswitch.nil?

        pnic_key = vswitch['pnic'].to_miq_a[0]
        pnic = inv['pnic'].to_miq_a.find { |p| p['key'] == pnic_key }
        next if pnic.nil?

        uid = pnic['device']
        guest_device = guest_device_uids.fetch_path(:pnic, uid)

        # Get the ip section
        ip = vnic.fetch_path('spec', 'ip')
        next if ip.nil?

        new_result = {
          :description  => uid,
          :dhcp_enabled => ip['dhcp'].to_s.downcase == 'true',
          :ipaddress    => ip['ipAddress'],
          :subnet_mask  => ip['subnetMask'],
        }

        result << new_result
        guest_device[:network] = new_result unless guest_device.nil?
      end
      result
    end

    def self.host_inv_to_scsi_lun_hashes(inv)
      inv = inv.fetch_path('config', 'storageDevice')

      result = []
      result_uids = {}
      return result, result_uids if inv.nil?

      inv['scsiLun'].to_miq_a.each do |data|
        new_result = {
          :uid_ems        => data['uuid'],

          :canonical_name => data['canonicalName'].blank? ? nil : data['canonicalName'],
          :lun_type       => data['lunType'].blank? ? nil : data['lunType'],
          :device_name    => data['deviceName'].blank? ? nil : data['deviceName'],
          :device_type    => data['deviceType'].blank? ? nil : data['deviceType'],
        }

        # :lun will be set later when we link to scsi targets

        cap = data['capacity']
        if cap.nil?
          new_result[:block] = new_result[:block_size] = new_result[:capacity] = nil
        else
          block = cap['block'].blank? ? nil : cap['block']
          block_size = cap['blockSize'].blank? ? nil : cap['blockSize']

          new_result[:block] = block
          new_result[:block_size] = block_size
          new_result[:capacity] = (block.nil? || block_size.nil?) ? nil : ((block.to_i * block_size.to_i) / 1024)
        end

        result << new_result
        result_uids[data['key']] = new_result
      end

      return result, result_uids
    end

    def self.host_inv_to_scsi_target_hashes(inv, guest_device_uids, scsi_lun_uids)
      inv = inv.fetch_path('config', 'storageDevice', 'scsiTopology', 'adapter')

      result = []
      return result if inv.nil?

      inv.to_miq_a.each do |adapter|
        adapter['target'].to_miq_a.each do |data|
          target = uid = data['target'].to_s

          new_result = {
            :uid_ems => uid,
            :target  => target
          }

          transport = data['transport']
          if transport.nil?
            new_result[:iscsi_name], new_result[:iscsi_alias], new_result[:address] = nil
          else
            new_result[:iscsi_name] = transport['iScsiName'].blank? ? nil : transport['iScsiName']
            new_result[:iscsi_alias] = transport['iScsiAlias'].blank? ? nil : transport['iScsiAlias']
            new_result[:address] = transport['address'].blank? ? nil : transport['address']
          end

          # Link the scsi target to the bus adapter
          guest_device = guest_device_uids[:adapter_id][adapter['adapter']]
          unless guest_device.nil?
            guest_device[:miq_scsi_targets] ||= []
            guest_device[:miq_scsi_targets] << new_result
          end

          # Link the scsi target to the scsi luns
          data['lun'].to_miq_a.each do |l|
            # We dup here so that later saving of ids doesn't cause a clash
            # TODO: Change this if we get to a better normalized structure in
            #   the database.
            lun = scsi_lun_uids[l['scsiLun']].dup
            unless lun.nil?
              lun[:lun] = l['lun'].to_s

              new_result[:miq_scsi_luns] ||= []
              new_result[:miq_scsi_luns] << lun
            end
          end

          result << new_result
        end
      end
      result
    end

    def self.host_inv_to_system_service_hashes(inv)
      inv = inv.fetch_path('config', 'service')

      result = []
      return result if inv.nil?

      inv['service'].to_miq_a.each do |data|
        result << {
          :name         => data['key'],
          :display_name => data['label'],
          :running      => data['running'].to_s == 'true',
        }
      end
      result
    end

    def self.host_inv_to_host_storages_hashes(inv, storage_inv, storage_uids)
      result = []

      storage_inv.each do |s_mor, s_inv|
        # Find the DatastoreHostMount object for this host
        host_mount = Array.wrap(s_inv["host"]).detect { |host| host["key"] == inv["MOR"] }
        next if host_mount.nil?

        read_only = host_mount.fetch_path("mountInfo", "accessMode") == "readOnly"

        result << {
          :storage   => storage_uids[s_mor],
          :read_only => read_only,
          :ems_ref   => s_mor
        }
      end

      result
    end

    def self.host_parent_resource(host_mor, inv)
      # Find the parent in the host_res or the cluster by host's mor
      parent = parent_type = nil
      [:host_res, :cluster].each do |type|
        parent_data = inv[parent_type = type]
        next if parent_data.nil?
        parent = parent_data.find { |_mor, parent_inv| RefreshParser.get_mors(parent_inv, 'host').include?(host_mor) }
        break unless parent.nil?
      end

      unless parent.nil?
        parent_mor, parent = *parent
      else
        parent_type = parent_mor = nil
      end
      return parent_type, parent_mor, parent
    end
  end
end
