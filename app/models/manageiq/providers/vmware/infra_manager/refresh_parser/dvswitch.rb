class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::Dvswitch
    def self.group_dvswitch_by_host(dvswitch_inv)
      dvswitch_by_host = Hash.new { |h, k| h[k] = [] }
      dvswitch_inv.each do |switch_mor, data|
        hosts = get_dvswitch_hosts(dvswitch_inv, switch_mor)
        hosts.each { |host_mor| dvswitch_by_host[host_mor] << data }
      end
      dvswitch_by_host
    end

    def self.get_dvswitch_hosts(dvswitch_inv, switch_mor)
      hosts_list = dvswitch_inv.fetch_path(switch_mor, 'config', 'host') || []
      hosts = hosts_list.collect { |host_data| host_data.fetch_path('config', 'host') }
      hosts += dvswitch_inv.fetch_path(switch_mor, 'summary', 'hostMember') || []
      hosts.uniq
    end

    def self.group_dvportgroup_by_host(dvportgroup_inv, dvswitch_inv)
      dvportgroup_by_host = Hash.new { |h, k| h[k] = [] }
      dvportgroup_inv.each do |_, data|
        # skip uplink portgroup
        next if data['tag'].detect { |e| e['key'] == 'SYSTEM/DVS.UPLINKPG' }

        hosts = get_dvswitch_hosts(dvswitch_inv, data.fetch_path('config', 'distributedVirtualSwitch'))
        hosts += data.fetch('host', [])
        hosts.uniq.each do |h|
          dvportgroup_by_host[h] << data
        end
      end
      dvportgroup_by_host
    end
  end
end
