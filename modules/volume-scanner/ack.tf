################################################################################
# Registration with Stream Security
#
# NOT YET ENABLED. `streamsec_aws_scanner_ack` does not exist in any published
# release of terraform-provider-streamsec — the newest release (1.13.3) ships
# [aws_account, aws_account_ack, aws_cost_ack, aws_kubernetes_cluster,
# aws_real_time_events_ack, aws_response_ack, azure_*, gcp_*, google_workspace]
# and no scanner ack. Leaving the block active makes `terraform init` fail with
# "Invalid resource type" before a single resource is planned, which would make
# the whole module undeployable. Uncomment it — and raise the streamsec version
# constraint in versions.tf to whichever release ships the resource — once the
# provider PR lands.
#
# Until then the region still appears in the Stream console with a live install
# state: the scanner's first progress report authenticates with the collection
# token and creates the region entry, and Stream stamps a region it creates that
# way as deployed. What is missing is the stack metadata (stack_id, stack_region,
# deployed_at) and every state transition after the first: a broken deploy is
# never badged failed, and terraform destroy never badges the region uninstalled.
# The default is applied only when the entry is created, so a region that was
# ever touched from the console — including merely generating its template, which
# records `pending` — keeps whatever install state the console last set. On such
# a region read the scan-status column, which the scanner does keep current.
#
# The ack goes through the provider, which is already authenticated, the same way
# every other module in this repo registers itself (streamsec_aws_account_ack,
# streamsec_aws_cost_ack, streamsec_aws_response_ack,
# streamsec_aws_real_time_events_ack).
#
# task_definition_arn is a tracked attribute rather than decoration: the
# CloudFormation custom resource passes it purely to force re-invocation on
# stack update so the status flips back to deployed. Without an equivalent here,
# a task-definition change would leave the recorded status stale.
#
################################################################################

# resource "streamsec_aws_scanner_ack" "this" {
#   cloud_account_id    = data.streamsec_aws_account.this.cloud_account_id
#   region              = local.region
#   cluster_arn         = aws_ecs_cluster.this.arn
#   task_definition_arn = aws_ecs_task_definition.this.arn
#
#   # No CloudFormation stack exists, but both fields are recorded against the
#   # region and surfaced in the console.
#   stack_id     = "terraform"
#   stack_region = local.region
#
#   depends_on = [
#     aws_cloudwatch_event_target.daily,
#     aws_iam_role_policy.task,
#     aws_iam_role_policy.orchestrator,
#   ]
# }
