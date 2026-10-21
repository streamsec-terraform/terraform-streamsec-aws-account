output "hub_task_role_arn" {
  description = "The hub scanner's task role, which the spoke role trusts"
  value       = module.hub_scanner.task_role_arn
}

output "spoke_role_arn" {
  description = "The role the hub's scanner assumes in the spoke account"
  value       = module.spoke_access.role_arn
}
