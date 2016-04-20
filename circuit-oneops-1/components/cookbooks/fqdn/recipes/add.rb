# Cookbook Name:: fqdn
# Recipe:: add
#
# Copyright 2016, Walmart Stores, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# builds a list of entries based on entrypoint, aliases, and then sets them in the set_dns_entries recipe
# no ManagedVia - recipes will run on the gw

# get the cloud and provider
cloud_name = node[:workorder][:cloud][:ciName]
provider_service = node[:workorder][:services][:dns][cloud_name][:ciClassName].split(".").last.downcase
provider = "fog"
case provider_service
when /infoblox/
  provider = "infoblox"
when /azuredns/
  provider = "azuredns"
when /designate/
  provider = "designate"
end

Chef::Log.info("Cloud name is: #{cloud_name}")
Chef::Log.info("Provider is: #{provider}")


# check for gdns service
gdns_service = nil
if node[:workorder][:services].has_key?("gdns") &&
   node[:workorder][:services][:gdns].has_key?(cloud_name)

   Chef::Log.info('Setting GDNS Service')
   gdns_service = node[:workorder][:services][:gdns][cloud_name]
end

# getting the environment attributes
env = node.workorder.payLoad["Environment"][0]["ciAttributes"]
Chef::Log.info("Env is: #{env}")

# skip in active (A/B update)
box = node[:workorder][:box][:ciAttributes]
if box.has_key?(:is_active) && box[:is_active] == "false"
  Chef::Log.info("skipping due to platform is_active false")
  return
end

include_recipe "fqdn::get_authoritative_nameserver"

# netscaler gslb
depends_on_lb = false
node.workorder.payLoad["DependsOn"].each do |dep|
  depends_on_lb = true if dep["ciClassName"] =~ /Lb/
end

Chef::Log.info("Depends on LB is: #{depends_on_lb}")

#Remove the old aliases
if provider =~ /azuredns/
  include_recipe 'azuredns::remove_old_aliases'
else
  include_recipe "fqdn::get_#{provider}_connection"
  include_recipe 'fqdn::remove_old_aliases_'+provider
end

node.set['dns_action'] = 'create'
#build the entry list
include_recipe 'fqdn::build_entries_list'

# set the records
if provider =~ /azuredns/
  include_recipe 'azuredns::set_dns_records'

  compute_service = node['workorder']['services']['compute'][cloud_name]['ciAttributes']
  express_route_enabled = compute_service['express_route_enabled']

  Chef::Log.info("express_route_enable is: #{express_route_enabled}")

  # IF it is public, update the DNS settings on the public ip.
  # it's only public because these settings aren't available to private ips within azure.
  if express_route_enabled == 'false'
    Chef::Log.info("calling azuredns::update_dns_on_pip recipe")
    include_recipe 'azuredns::update_dns_on_pip'
  end
else
  include_recipe 'fqdn::set_dns_entries_'+provider
end

if env.has_key?("global_dns") && env["global_dns"] == "true" && depends_on_lb &&
   !gdns_service.nil? && gdns_service["ciAttributes"]["gslb_authoritative_servers"] != '[]'

  if provider =~ /azuredns/
    include_recipe "azuretrafficmanager::add"
  else
    include_recipe "netscaler::get_dc_lbvserver"
    include_recipe "netscaler::add_gslb_vserver"
    include_recipe "netscaler::add_gslb_service"
    include_recipe "netscaler::logout"
  end
end


