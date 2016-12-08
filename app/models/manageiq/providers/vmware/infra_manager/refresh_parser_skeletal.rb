module ManageIQ::Providers
  module Vmware
    module InfraManager::RefreshParserSkeletal
      def self.parse_updates(updates)
        result = {}

        # Create a hash on ManagedEntity type from a flat updates array
        inv = updates_by_mor_type(updates)

        result[:folders]        = folder_inv_to_hashes(inv['Folder'] + inv['Datacenter'])
        result[:storages]       = storage_inv_to_hashes(inv['Datastore'])
        result[:clusters]       = cluster_inv_to_hashes(inv['ComputeResource'] + inv['ClusterComputeResource'])
        result[:resource_pools] = rp_inv_to_hashes(inv['ResourcePool'])
        result[:hosts]          = host_inv_to_hashes(inv['HostSystem'])
        result[:lans]           = lan_inv_to_hashes(inv['Network'] + inv['DistributedVirtualPortgroup'])
        result[:vms]            = vm_inv_to_hashes(inv['VirtualMachine'])

        result
      end

      def self.folder_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          type = case mor.vimType
                 when 'Datacenter'
                   'Datacenter'
                 when 'Folder'
                   'EmsFolder'
                 end
          next if type.nil?

          new_result = {
            :type        => type,
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :uid_ems     => mor,
            :name        => props['name'],
          }

          result << new_result
        end

        result
      end
      private_class_method :folder_inv_to_hashes

      def self.storage_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          new_result = {
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :name        => props['name'],
            :location    => props['summary.url']
          }

          result << new_result
        end

        result
      end
      private_class_method :storage_inv_to_hashes

      def self.cluster_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          new_result = {
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :uid_ems     => mor,
            :name        => props['name']
          }

          result << new_result
        end

        result
      end
      private_class_method :cluster_inv_to_hashes

      def self.rp_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          new_result = {
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :uid_ems     => mor,
            :name        => props['name']
          }

          result << new_result
        end

        result
      end
      private_class_method :rp_inv_to_hashes

      def self.host_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          # TODO: check if is an ESX or ESXi host
          type = "ManageIQ::Providers::Vmware::InfraManager::HostEsx"

          new_result = {
            :type        => type,
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :name        => props['name'],
          }

          result << new_result
        end

        result
      end
      private_class_method :host_inv_to_hashes

      def self.lan_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          new_result = {
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :name        => props['name'],
          }

          result << new_result
        end

        result
      end
      private_class_method :lan_inv_to_hashes

      def self.vm_inv_to_hashes(inv)
        result = []

        inv.each do |mor, props|
          template = props['summary.config.template'].to_s.downcase == 'true'
          type     = "ManageIQ::Providers::Vmware::InfraManager::#{template ? 'Template' : 'Vm'}"

          raw_power_state = template ? 'never' : props['summary.runtime.powerState']

          new_result = {
            :type            => type,
            :ems_ref         => mor,
            :ems_ref_obj     => mor,
            :vendor          => 'vmware',
            :name            => props['name'],
            :uid_ems         => props['summary.config.uuid'],
            :template        => template,
            :raw_power_state => raw_power_state
          }

          result << new_result
        end

        result
      end
      private_class_method :vm_inv_to_hashes

      def self.updates_by_mor_type(updates)
        result = Hash.new { |h, k| h[k] = [] }

        updates.each do |_kind, mor, props|
          result[mor.vimType] << [mor, props]
        end

        result
      end
      private_class_method :updates_by_mor_type
    end
  end
end
