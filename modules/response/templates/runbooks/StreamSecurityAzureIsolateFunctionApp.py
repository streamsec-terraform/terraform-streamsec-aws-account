#!/usr/bin/env python3
import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.network.models import NetworkSecurityGroup, SecurityRule
from azure.mgmt.web import WebSiteManagementClient

def parse_function_app_id(app_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Web/sites/(?P<app>[^/]+)")
    match = re.match(pattern, app_id)
    if not match:
        raise ValueError(f"Invalid Function App ID format: {app_id}")
    return match.group("sub"), match.group("rg"), match.group("app")

def parse_subnet_id(subnet_id):
    pattern = (
        r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
        r"providers/Microsoft.Network/virtualNetworks/(?P<vnet>[^/]+)/subnets/(?P<subnet>[^/]+)"
    )
    match = re.match(pattern, subnet_id, re.IGNORECASE)
    if not match:
        raise ValueError(f"Invalid subnet ID format: {subnet_id}")
    return match.group("rg"), match.group("vnet"), match.group("subnet")


def get_isolated_nsg(network_client, resource_group, nsg_name, location):
    nsg_name = f"{nsg_name}-{location.replace(' ', '-')}"
    try:
        nsg = network_client.network_security_groups.get(resource_group, nsg_name)
        if nsg.location.lower() != location.lower():
            raise Exception(f"NSG '{nsg_name}' exists in a different location: {nsg.location}")
        print(f" NSG '{nsg_name}' already exists.")
    except Exception:
        params = NetworkSecurityGroup(location=location)
        poller = network_client.network_security_groups.begin_create_or_update(resource_group, nsg_name, params)
        poller.result()
        print(f" NSG '{nsg_name}' created successfully.")

    deny_inbound = SecurityRule(
        name="StreamDenyAllInbound",
        protocol="*",
        source_address_prefix="*",
        destination_address_prefix="*",
        access="Deny",
        direction="Inbound",
        priority=100,
        source_port_range="*",
        destination_port_range="*")

    deny_outbound = SecurityRule(
        name="StreamDenyAllOutbound",
        protocol="*",
        source_address_prefix="*",
        destination_address_prefix="*",
        access="Deny",
        direction="Outbound",
        priority=101,
        source_port_range="*",
        destination_port_range="*")

    existing_rules = list(network_client.security_rules.list(resource_group, nsg_name))
    for rule in existing_rules:
        network_client.security_rules.begin_delete(resource_group, nsg_name, rule.name).result()

    network_client.security_rules.begin_create_or_update(resource_group, nsg_name, deny_inbound.name,
                                                             deny_inbound).result()

    network_client.security_rules.begin_create_or_update(resource_group, nsg_name, deny_outbound.name,
                                                             deny_outbound).result()

    return network_client.network_security_groups.get(resource_group, nsg_name)

def isolate_function_app(app_id, uami_client_id):
    subscription_id, resource_group, app_name = parse_function_app_id(app_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    web_client = WebSiteManagementClient(credential, subscription_id)
    network_client = NetworkManagementClient(credential, subscription_id)
    nsg_name = "IsolatedSG"

    try:
        vnet_connections = web_client.web_apps.list_vnet_connections(resource_group, app_name)
        vnet_connections = list(vnet_connections)

        if not vnet_connections:
            print(f"Function App '{app_name}' is not integrated with a VNet. Skipping.")
            return

        subnet_id = vnet_connections[0].vnet_resource_id
    except:
        print(f"Function App '{app_name}' is not integrated with a VNet. Skipping.")
        return

    subnet_rg, vnet_name, subnet_name = parse_subnet_id(subnet_id)
    subnet = network_client.subnets.get(subnet_rg, vnet_name, subnet_name)
    vnet = network_client.virtual_networks.get(subnet_rg, vnet_name)
    location = vnet.location
    isolation_nsg = get_isolated_nsg(network_client, subnet_rg, nsg_name, location)

    if subnet.network_security_group and subnet.network_security_group.id.lower() == isolation_nsg.id.lower():
        print(f"Subnet '{subnet_name}' already associated with isolation NSG.")
        return

    subnet.network_security_group = isolation_nsg
    poller = network_client.subnets.begin_create_or_update(subnet_rg, vnet_name, subnet_name, subnet)
    poller.result()
    print(f"Subnet '{subnet_name}' updated with isolation NSG.")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <function_app_id> <uami_client_id>")
        sys.exit(1)

    app_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Function App ID: {app_id}, UAMI Client ID: {uami_client_id}")
    isolate_function_app(app_id, uami_client_id)
