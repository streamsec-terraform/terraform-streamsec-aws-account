    #!/usr/bin/env python3

import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.network import NetworkManagementClient


def parse_nsg_id(nsg_id: str):
    """
    Parses the NSG ID to extract subscription ID, resource group, and NSG name.
    """
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
                   r"providers/Microsoft.Network/networkSecurityGroups/(?P<nsg>[^/]+)")
    match = re.match(pattern, nsg_id)
    if not match:
        raise ValueError(f"Invalid NSG ID format: {nsg_id}")
    return match.group("sub"), match.group("rg"), match.group("nsg")


def port_includes_target(port_def: str, target_port: int = 22) -> bool:
    """
    Checks if the given port definition includes the target port.
    """
    try:
        if port_def == "*":
            return True
        if "-" in port_def:
            start, end = map(int, port_def.split("-"))
            return start <= target_port <= end
        return int(port_def) == target_port
    except ValueError:
        return False

def find_available_priority(starting: int, existing: set) -> int:
    """
    Finds the next available priority slot starting from the given value.
    Searches downwards first, then upwards, within the allowed range of 100 to 4096.
    """
    # Try going down first
    for p in range(starting - 1, 99, -1):
        if p not in existing:
            return p
    # Then try going up
    for p in range(starting + 1, 4097):
        if p not in existing:
            return p
    raise ValueError("No available priority slots in allowed range (100-4096)")

def extract_dest_ports(rule):
    """
    Extracts destination ports from the rule, combining ranges and individual ports.
    """
    dest_ports = rule.destination_port_ranges or []
    if rule.destination_port_range:
        dest_ports.extend([p.strip() for p in rule.destination_port_range.split(",") if p.strip()])
    return dest_ports

def is_rule_exposing_port(rule, target_port, dest_ports):
    """
    Determines if the rule is exposing the target port to public sources.
    """
    public_sources = {"0.0.0.0/0", "*", "internet"}
    if rule.direction.lower() != "inbound" or rule.protocol.lower() not in {"tcp","*"} or rule.access.lower() != "allow":
        return False

    if not any(port_includes_target(p, target_port) for p in dest_ports):
        return False

    sources = rule.source_address_prefixes or []
    if rule.source_address_prefix:
        sources.append(rule.source_address_prefix)
    return any(str(source).lower() in public_sources for source in sources)


def build_new_rules(rule, port_range, target_port, existing_priorities, dest_ports_without_target):
    """
        Given a port range that includes the target port (22 by default), this function constructs one or more
        new security rules that preserve access to the remaining ports (not including the target).
        It handles wildcard ranges (*), numeric ranges (e.g., 20-30), and single ports.
        """
    new_rules = []
    if port_range == "*":
        lower_priority = find_available_priority(int(rule.priority), existing_priorities)
        existing_priorities.add(lower_priority)
        new_rules.append({
                "name": f"{rule.name}-lower",
                "priority": lower_priority,
                "destination_port_range": f"0-{target_port - 1}"
        })
        new_rules.append({
                "name": f"{rule.name}-upper",
                "priority": rule.priority,
                "destination_port_range": f"{target_port + 1}-65535"
        })
    elif port_includes_target(port_range, target_port):
        try:
            if "-" in port_range:
                start_port, end_port = map(int, port_range.split("-"))
            else:
                start_port = end_port = int(port_range)
        except ValueError:
            raise ValueError(f"Invalid port range format: {port_range}")

        if start_port < target_port:
            low_priority = find_available_priority(int(rule.priority), existing_priorities)
            existing_priorities.add(low_priority)
            lower_range = f"{start_port}" if start_port == target_port - 1 else f"{start_port}-{target_port - 1}"
            new_rules.append({
                    "name": f"{rule.name}-lower",
                    "priority": low_priority,
                    "destination_port_range": lower_range
                })
        if target_port < end_port:
            upper_range = f"{end_port}" if end_port == target_port + 1 else f"{target_port + 1}-{end_port}"
            new_rules.append({
                    "name": f"{rule.name}-upper",
                    "priority": rule.priority,
                    "destination_port_range": upper_range
                })
        if start_port == end_port == target_port and dest_ports_without_target:
            new_rules.append({
                    "name": rule.name,
                    "priority": rule.priority
                })
    return new_rules


def create_security_rule_dict(rule, new_rule, dest_ports_without_target):
    """
       Builds a dictionary representing a new NSG security rule, based on the structure of the original rule.
       It retains original properties (protocol, access, direction, etc.) and constructs new port definitions
       from the destination port range and additional ports if applicable.
       """
    security_rule = {
            "name": new_rule["name"],
            "protocol": rule.protocol,
            "source_port_range": rule.source_port_range,
            "destination_port_range": new_rule.get("destination_port_range", ""),
            "access": rule.access,
            "direction": rule.direction,
            "priority": new_rule["priority"]
        }
    if dest_ports_without_target:
        combined_ports = dest_ports_without_target[:]
        extra_range = new_rule.get("destination_port_range")
        if extra_range:
            combined_ports.append(extra_range)
            security_rule.pop("destination_port_range", None)
        if combined_ports:
            security_rule["destination_port_ranges"] = combined_ports

    if rule.source_address_prefixes:
        security_rule["source_address_prefixes"] = rule.source_address_prefixes
    elif rule.source_address_prefix:
        security_rule["source_address_prefix"] = rule.source_address_prefix
    if rule.destination_address_prefixes:
        security_rule["destination_address_prefixes"] = rule.destination_address_prefixes
    elif rule.destination_address_prefix:
        security_rule["destination_address_prefix"] = rule.destination_address_prefix

    return security_rule

def remove_public_ssh_rules(nsg_id: str, uami_client_id: str, target_port: int = 22):
    """
        Main entry point that scans all NSG rules in a given NSG, deletes rules exposing the target port (default: 22)
        to public sources, and creates replacement rules for the remaining port ranges (if applicable).
        This function handles authentication, NSG retrieval, rule deletion, and rule recreation.
        """
    subscription_id, resource_group, nsg_name = parse_nsg_id(nsg_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    network_client = NetworkManagementClient(credential, subscription_id)
    print(f"Fetching NSG '{nsg_name}' in resource group '{resource_group}'")
    try:
        nsg = network_client.network_security_groups.get(resource_group, nsg_name)
        rules = list(nsg.security_rules)
    except Exception as e:
        raise Exception(f"Failed to retrieve NSG '{nsg_name}': {e}")

    existing_priorities = {int(r.priority) for r in rules if r.priority is not None}
    for rule in rules:
        try:
            dest_ports = extract_dest_ports(rule)
            dest_ports_without_target = [port for port in dest_ports if not port_includes_target(port, target_port)]
            if not is_rule_exposing_port(rule, target_port, dest_ports):
                continue

            print(f"Deleting rule '{rule.name}' exposing port {target_port} to public sources")
            network_client.security_rules.begin_delete(resource_group, nsg_name, rule.name).result()
            print(f"Rule '{rule.name}' deleted successfully.")

            for port_range in dest_ports:
                new_rules = build_new_rules(rule, port_range, target_port, existing_priorities, dest_ports_without_target)
                for new_rule in new_rules:
                    security_rule = create_security_rule_dict(rule, new_rule, dest_ports_without_target)
                    print(f"Creating replacement rule '{security_rule['name']}' with priority {security_rule['priority']}")
                    try:
                        network_client.security_rules.begin_create_or_update(
                                resource_group, nsg_name, security_rule["name"], security_rule).result()
                        print(f"Rule '{security_rule['name']}' created successfully.")
                    except Exception as e:
                        raise Exception(f"Failed to create rule '{security_rule['name']}': {e}")

        except Exception as err:
            raise Exception(f"Failed to create new rule '{rule.name}': {err}")
    print("Completed NSG rule adjustments.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python remove_port_from_nsg.py <SecurityGroupId> <uami_client_id>")
        sys.exit(1)

    nsg_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters:- SecurityGroupId: {nsg_id}- UAMI Client ID: {uami_client_id}")
    remove_public_ssh_rules(nsg_id, uami_client_id)
