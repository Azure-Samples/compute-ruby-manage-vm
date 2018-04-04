#!/usr/bin/env ruby

require 'azure_mgmt_resources'
require 'azure_mgmt_network'
require 'azure_mgmt_storage'
require 'azure_mgmt_compute'

LOCAL = 'local'
GROUP_NAME = 'azurestack-sample-compute'

Storage = Azure::Storage::Profiles::V2017_03_09::Mgmt
Network = Azure::Network::Profiles::V2017_03_09::Mgmt
Compute = Azure::Compute::Profiles::V2017_03_09::Mgmt
Resources = Azure::Resources::Profiles::V2017_03_09::Mgmt

StorageModels = Storage::Models
NetworkModels = Network::Models
ComputeModels = Compute::Models
ResourceModels = Resources::Models

# This sample shows how to manage a Azure virtual machines using using the Azure Resource Manager APIs for Ruby.
#
# This script expects that the following environment vars are set:
#
# AZURE_TENANT_ID: with your Azure Active Directory tenant id or domain
# AZURE_CLIENT_ID: with your Azure Active Directory Application Client ID
# AZURE_CLIENT_SECRET: with your Azure Active Directory Application Secret
# AZURE_SUBSCRIPTION_ID: with your Azure Subscription Id
#
def run_example
  #
  # Create the Resource Manager Client with an Application (service principal) token provider
  #
  subscription_id = ENV['AZURE_SUBSCRIPTION_ID'] || '11111111-1111-1111-1111-111111111111' # your Azure Subscription Id
  
  # This parameter is only required for AzureStack or other soverign clouds. Pulic Azure already has these settings by default.
  active_directory_settings = get_active_directory_settings(ENV['ARM_ENDPOINT'])


  provider = MsRestAzure::ApplicationTokenProvider.new(
      ENV['AZURE_TENANT_ID'],
      ENV['AZURE_CLIENT_ID'],
      ENV['AZURE_CLIENT_SECRET'],
      active_directory_settings
      )
  credentials = MsRest::TokenCredentials.new(provider)

  options = {
      credentials: credentials,
      subscription_id: subscription_id,
      active_directory_settings: active_directory_settings,
      base_url: ENV['ARM_ENDPOINT']
  }

  resource_client = Azure::Resources::Profiles::V2017_03_09::Mgmt::Client.new(options)
  network_client = Azure::Network::Profiles::V2017_03_09::Mgmt::Client.new(options)
  storage_client = Azure::Storage::Profiles::V2017_03_09::Mgmt::Client.new(options)
  compute_client = Azure::Compute::Profiles::V2017_03_09::Mgmt::Client.new(options)

  #
  # Managing resource groups
  #
  resource_group_params = ResourceModels::ResourceGroup.new.tap do |rg|
    rg.location = LOCAL
  end

  # Create Resource group
  puts 'Create Resource Group'
  print_group resource_client.resource_groups.create_or_update(GROUP_NAME, resource_group_params)

  # Create a Storage Account. Encryption settings are only supported on blobs for AzureStack.
  postfix = rand(1000)
  storage_account_name = "rubystor#{postfix}"
  puts "Creating a standard storage account named #{storage_account_name} in resource group #{GROUP_NAME}"
  storage_create_params = StorageModels::StorageAccountCreateParameters.new.tap do |account|
    account.location = LOCAL
    account.sku = StorageModels::Sku.new.tap do |sku|
      sku.name = StorageModels::SkuName::StandardLRS
      sku.tier = StorageModels::SkuTier::Standard
    end
    account.kind = StorageModels::Kind::Storage
  end
  print_item storage_account = storage_client.storage_accounts.create(GROUP_NAME, storage_account_name, storage_create_params)

  puts 'Creating a virtual network for the VM'
  vnet_create_params = NetworkModels::VirtualNetwork.new.tap do |vnet|
    vnet.location = LOCAL
    vnet.address_space = NetworkModels::AddressSpace.new.tap do |addr_space|
      addr_space.address_prefixes = ['10.0.0.0/16']
    end
    vnet.dhcp_options = NetworkModels::DhcpOptions.new.tap do |dhcp|
      dhcp.dns_servers = ['8.8.8.8']
    end
    vnet.subnets = [
        NetworkModels::Subnet.new.tap do |subnet|
          subnet.name = 'rubySampleSubnet'
          subnet.address_prefix = '10.0.0.0/24'
        end
    ]
  end
  print_item vnet = network_client.virtual_networks.create_or_update(GROUP_NAME, 'sample-ruby-vnet', vnet_create_params)

  puts 'Creating a public IP address for the VM'
  public_ip_params = NetworkModels::PublicIPAddress.new.tap do |ip|
    ip.location = LOCAL
    ip.public_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
    ip.dns_settings = NetworkModels::PublicIPAddressDnsSettings.new.tap do |dns|
      dns.domain_name_label = "stack-sample-dns#{postfix}"
    end
  end
  print_item public_ip = network_client.public_ipaddresses.create_or_update(GROUP_NAME, 'sample-ruby-pubip', public_ip_params)

  vm = create_vm(compute_client, network_client, LOCAL, 'firstvm', storage_account, vnet.subnets[0], public_ip)

  puts 'Listing all of the resources within the group'
  resource_client.resource_groups.list_resources(GROUP_NAME).each do |res|
    print_item res
  end
  puts ''

  export_template(resource_client)

  puts "Connect to your new virtual machine via: 'ssh -p 22 #{vm.os_profile.admin_username}@#{public_ip.dns_settings.fqdn}'. Admin Password is: #{vm.os_profile.admin_password}"

  puts 'Now that we have built a virtual machine, lets turn off the virtual machine.'
  puts 'Press any key to continue'
  gets
  puts 'Turning off the virtual machine...'
  compute_client.virtual_machines.power_off(GROUP_NAME, vm.name)

  puts 'Your virtual machine is now off. Lets start the virtual machine.'
  puts 'Press any key to continue'
  gets
  puts 'Starting the virtual machine...'
  compute_client.virtual_machines.start(GROUP_NAME, vm.name)

  puts 'Your virtual machine has started. Lets restarting the virtual machine.'
  puts 'Press any key to continue'
  gets
  puts 'Re-Starting the virtual machine...'
  compute_client.virtual_machines.restart(GROUP_NAME, vm.name)
  puts 'Your virtual machine is now on.'

  puts 'Press any key to continue and delete the sample resources'
  gets

  # Delete Resource group and everything in it
  puts 'Delete Resource Group'
  resource_client.resource_groups.delete(GROUP_NAME)
  puts "\nDeleted: #{GROUP_NAME}"

end

def print_group(resource)
  puts "\tname: #{resource.name}"
  puts "\tid: #{resource.id}"
  puts "\tlocation: #{resource.location}"
  puts "\ttags: #{resource.tags}"
  puts "\tproperties:"
  print_item(resource.properties)
end

def print_item(resource)
  resource.instance_variables.sort.each do |ivar|
    str = ivar.to_s.gsub /^@/, ''
    if resource.respond_to? str.to_sym
      puts "\t\t#{str}: #{resource.send(str.to_sym)}"
    end
  end
  puts "\n\n"
end

def export_template(resource_client)
  puts "Exporting the resource group template for #{GROUP_NAME}"
  export_result = resource_client.resource_groups.export_template(
      GROUP_NAME,
      ResourceModels::ExportTemplateRequest.new.tap{ |req| req.resources = ['*'] }
  )
  puts export_result.template
  puts ''
end

# Create a Virtual Machine and return it
def create_vm(compute_client, network_client, location, vm_name, storage_acct, subnet, public_ip)
  puts "Creating a network interface for the VM #{vm_name}"
  print_item nic = network_client.network_interfaces.create_or_update(
      GROUP_NAME,
      "sample-ruby-nic-#{vm_name}",
      NetworkModels::NetworkInterface.new.tap do |interface|
        interface.location = LOCAL
        interface.ip_configurations = [
            NetworkModels::NetworkInterfaceIPConfiguration.new.tap do |nic_conf|
              nic_conf.name = "sample-ruby-nic-#{vm_name}"
              nic_conf.private_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
              nic_conf.subnet = subnet
              nic_conf.public_ipaddress = public_ip
            end
        ]
      end
  )

  puts 'Creating a Ubuntu 16.04.0-LTS Standard DS2 V2 virtual machine w/ a public IP'
  vm_create_params = ComputeModels::VirtualMachine.new.tap do |vm|
    vm.location = location
    vm.os_profile = ComputeModels::OSProfile.new.tap do |os_profile|
      os_profile.computer_name = vm_name
      os_profile.admin_username = 'notAdmin'
      os_profile.admin_password = SecureRandom.uuid 
    end

    vm.storage_profile = ComputeModels::StorageProfile.new.tap do |store_profile|
      store_profile.image_reference = ComputeModels::ImageReference.new.tap do |ref|
        ref.publisher = 'Canonical'
        ref.offer = 'UbuntuServer'
        ref.sku = '16.04-LTS'
        ref.version = '16.04.201801260'
      end
      store_profile.os_disk = ComputeModels::OSDisk.new.tap do |os_disk|
        os_disk.name = "sample-os-disk-#{vm_name}"
        os_disk.caching = ComputeModels::CachingTypes::None
        os_disk.create_option = ComputeModels::DiskCreateOptionTypes::FromImage
        os_disk.vhd = ComputeModels::VirtualHardDisk.new.tap do |vhd|
          vhd.uri = "https://#{storage_acct.name}.blob.#{public_ip.dns_settings.fqdn}/rubycontainer/#{vm_name}.vhd"
        end
      end
    end

    vm.hardware_profile = ComputeModels::HardwareProfile.new.tap do |hardware|
      hardware.vm_size = ComputeModels::VirtualMachineSizeTypes::StandardDS2V2
    end

    vm.network_profile = ComputeModels::NetworkProfile.new.tap do |net_profile|
      net_profile.network_interfaces = [
          ComputeModels::NetworkInterfaceReference.new.tap do |ref|
            ref.id = nic.id
            ref.primary = true
          end
      ]
    end
  end

  ssh_pub_location = File.expand_path('~/.ssh/id_rsa.pub')
  if File.exists? ssh_pub_location
    puts "Found SSH public key in #{ssh_pub_location}. Disabling password and enabling SSH authentication."
    key_data = File.read(ssh_pub_location)
    puts "Using public key: #{key_data}"
    vm_create_params.os_profile.linux_configuration = ComputeModels::LinuxConfiguration.new.tap do |linux|
      linux.disable_password_authentication = true
      linux.ssh = ComputeModels::SshConfiguration.new.tap do |ssh_config|
        ssh_config.public_keys = [
            ComputeModels::SshPublicKey.new.tap do |pub_key|
              pub_key.key_data = key_data
              pub_key.path = '/home/notAdmin/.ssh/authorized_keys'
            end
        ]
      end
    end
  end

  print_item vm = compute_client.virtual_machines.create_or_update(GROUP_NAME, "sample-ruby-vm-#{vm_name}", vm_create_params)
  vm
end

  # Get Authentication endpoints using Arm Metadata Endpoints
  def get_active_directory_settings(armEndpoint)
    settings = MsRestAzure::ActiveDirectoryServiceSettings.new
    response = Net::HTTP.get_response(URI("#{armEndpoint}/metadata/endpoints?api-version=1.0"))
    status_code = response.code
    response_content = response.body
    unless status_code == "200"
      error_model = JSON.load(response_content)
      fail MsRestAzure::AzureOperationError.new("Getting Azure Stack Metadata Endpoints", response, error_model)
    end

    result = JSON.load(response_content)
    settings.authentication_endpoint = result['authentication']['loginEndpoint'] unless result['authentication']['loginEndpoint'].nil?
    settings.token_audience = result['authentication']['audiences'][0] unless result['authentication']['audiences'][0].nil?
    settings
  end

if $0 == __FILE__
  run_example
end
