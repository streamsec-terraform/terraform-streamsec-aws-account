#!/usr/bin/env python3

import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.network import NetworkManagementClient
from azure.core.exceptions import HttpResponseError


def parse_nsg_id(nsg_id: str):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Network/networkSecurityGroups/(?P<nsg>[^/]+)")
    match = re.match(pattern, nsg_id)
    if not match:
        raise ValueError(f"Invalid NSG ID format: {nsg_id}")
    return match.group("sub"), match.group("rg"), match.group("nsg")


def is_unrestricted_tcp(rule):
    if rule.direction.lower() != "inbound":
        return False
    if rule.access.lower() != "allow":
        return False
    if rule.protocol.lower() not in {"tcp", "*"}:
        return False

    dest_ports = rule.destination_port_ranges or []
    if rule.destination_port_range:
        dest_ports.extend([p.strip() for p in rule.destination_port_range.split(",") if p.strip()])

    if not any(p in {"*", "0-65535"} for p in dest_ports):
        return False

    sources = rule.source_address_prefixes or []
    if rule.source_address_prefix:
        sources.append(rule.source_address_prefix)

    return any(str(s).lower() in {"*", "0.0.0.0/0", "internet"} for s in sources)


def remove_unrestricted_tcp_rules(nsg_id: str, uami_client_id: str):
    subscription_id, resource_group, nsg_name = parse_nsg_id(nsg_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    network_client = NetworkManagementClient(credential, subscription_id)

    print(f"Fetching NSG '{nsg_name}' in resource group '{resource_group}'")
    try:
        nsg = network_client.network_security_groups.get(resource_group, nsg_name)
        rules = list(nsg.security_rules)
    except Exception as e:
        raise Exception(f"Failed to retrieve NSG '{nsg_name}': {e}")

    for rule in rules:
        try:
            if is_unrestricted_tcp(rule):
                print(f"Deleting unrestricted TCP rule '{rule.name}'...")
                network_client.security_rules.begin_delete(resource_group, nsg_name, rule.name).result()
                print(f"Rule '{rule.name}' deleted successfully.")
        except Exception as err:
            raise Exception(f"Failed to delete rule '{rule.name}': {err}")

    print("Completed NSG unrestricted rule cleanup.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python remove_unrestricted_tcp_rules.py <SecurityGroupId> <uami_client_id>")
        sys.exit(1)

    nsg_id = sys.argv[1]
    uami_client_id = sys.argv[2]

    print(f"Received Parameters: SecurityGroupId={nsg_id}, UAMI Client ID={uami_client_id}")
    remove_unrestricted_tcp_rules(nsg_id, uami_client_id)
