describe ManageIQ::Providers::Vmware::InfraManager::RefreshParser::Filter do
  context "filter_vc_data" do
    let(:ems) { FactoryGirl.create(:ems_vmware) }

    before do
      @refresher = ems.refresher.new([ems])
      @refresher.instance_variable_set(:@vc_data, vc_data)
    end

    context "with 1 host and 1 vm" do
      let(:vm)   { FactoryGirl.create(:vm_with_ref) }
      let(:host) { FactoryGirl.create(:host_with_ref) }
      let(:vc_data) do
        inv = Hash.new { |h, k| h[k] = {} }

        inv[:host][host.ems_ref] = { "MOR" => host.ems_ref }
        inv[:vm][vm.ems_ref]     = {
          "MOR"     => vm.ems_ref,
          "summary" => { "runtime" => { "host" => host.ems_ref } }
        }

        inv
      end

      context "targeting the ems" do
        it "returns the full inventory" do
          filtered_data = @refresher.filter_vc_data(ems, ems)
          expect(filtered_data).to eq(vc_data)
        end
      end

      context "targeting a vm" do
        it "returns relevent data" do
          filtered_data = @refresher.filter_vc_data(ems, vm)

          expect(filtered_data[:host].count).to eq(1)
          expect(filtered_data[:host]).to       include(host.ems_ref)

          expect(filtered_data[:vm].count).to   eq(1)
          expect(filtered_data[:vm]).to         include(vm.ems_ref)
        end
      end
    end

    context "with a vm and no host" do
      let(:vm)          { FactoryGirl.create(:vm_with_ref) }
      let(:dc)          { FactoryGirl.create(:datacenter, :ems_ref => "datacenter-1", :name => "dc1") }
      let(:root_folder) { FactoryGirl.create(:ems_folder, :ems_ref => "group-d1",     :name => "Datacenters") }
      let(:vm_folder)   { FactoryGirl.create(:ems_folder, :ems_ref => "group-v3",     :name => "vm") }

      let(:vc_data) do
        inv = Hash.new { |h, k| h[k] = {} }

        inv[:vm][vm.ems_ref] = {
          "MOR"     => vm.ems_ref,
          "summary" => { "runtime" => { "host" => "host-1234" } }
        }

        inv[:dc][dc.ems_ref] = {
          "MOR"    => dc.ems_ref,
          "parent" => root_folder.ems_ref
        }

        inv[:folder][root_folder.ems_ref] = {
          "MOR"         => root_folder.ems_ref,
          "childEntity" => [dc.ems_ref]
        }

        inv[:folder][vm_folder.ems_ref] = {
          "MOR"         => vm_folder.ems_ref,
          "childEntity" => [vm.ems_ref],
          "parent"      => dc.ems_ref
        }

        inv
      end

      context "targeting a vm" do
        # Test to make sure that a targeted refresh of a VM with no host
        # in inventory still returns the root folder
        it "returns the root folder" do
          filtered_data = @refresher.filter_vc_data(ems, vm)

          expect(filtered_data[:folder]).to include(root_folder.ems_ref)
        end
      end
    end

    context "with two datacenters" do
      let(:dc1)         { FactoryGirl.create(:datacenter, :ems_ref => "datacenter-1", :ems_ref_obj => "datacenter-1", :name => "dc1") }
      let(:dc2)         { FactoryGirl.create(:datacenter, :ems_ref => "datacenter-2", :name => "dc2") }
      let(:root_folder) { FactoryGirl.create(:ems_folder, :ems_ref => "group-d1",     :name => "Datacenters") }
      let(:vm_folder_1) { FactoryGirl.create(:ems_folder, :ems_ref => "group-v3",     :name => "vm") }
      let(:vm_folder_2) { FactoryGirl.create(:ems_folder, :ems_ref => "group-v4",     :name => "vm") }
      let(:vc_data) do
        inv = Hash.new { |h, k| h[k] = {} }

        [[dc1.ems_ref, vm_folder_1.ems_ref], [dc2.ems_ref, vm_folder_2.ems_ref]].each do |dc_ref, folder_ref|
          inv[:dc][dc_ref] = {
            "MOR"      => dc_ref,
            "parent"   => root_folder.ems_ref,
            "vmFolder" => folder_ref
          }
        end

        inv[:folder][root_folder.ems_ref] = {
          "MOR"         => root_folder.ems_ref,
          "childEntity" => [dc1.ems_ref, dc2.ems_ref]
        }

        [[vm_folder_1.ems_ref, dc1.ems_ref], [vm_folder_2.ems_ref, dc2.ems_ref]].each do |folder_ref, dc_ref|
          inv[:folder][folder_ref] = {
            "MOR"    => folder_ref,
            "parent" => dc_ref
          }
        end

        inv
      end

      context "targeting a datacenter" do
        it "returns the root folder" do
          filtered_data = @refresher.filter_vc_data(ems, dc1)
          expect(filtered_data[:folder]).to include(root_folder.ems_ref)
        end

        it "doesn't return the other datacenter" do
          filtered_data = @refresher.filter_vc_data(ems, dc1)
          expect(filtered_data[:dc]).not_to include(dc2.ems_ref)
        end

        it "includes the correct child folders" do
          filtered_data = @refresher.filter_vc_data(ems, dc1)
          expect(filtered_data[:folder]).to     include(vm_folder_1.ems_ref)
          expect(filtered_data[:folder]).not_to include(vm_folder_2.ems_ref)
        end
      end
    end
  end
end
