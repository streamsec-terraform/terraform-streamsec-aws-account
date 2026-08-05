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
# Until then the region still appears in the Stream console: the scanner's own
# scanner_report call authenticates with the collection token and
# _upsert_scanner_region appends the region entry on first report. What is
# missing is the install-state `status` field and the `uninstalled` report on
# destroy.
#
# WHY A PROVIDER RESOURCE AND NOT A LAMBDA
#
# The CloudFormation StreamScannerAcknowledger Lambda exists only because
# CloudFormation has no authenticated channel back to Stream — the backend has
# to mint a one-time per-region acknowledge_token at template-render time and
# bake it into the stack. The provider is already authenticated, so the ack goes
# straight through it, the same way every other module in this repo registers
# itself (streamsec_aws_account_ack, streamsec_aws_cost_ack,
# streamsec_aws_response_ack, streamsec_aws_real_time_events_ack).
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
#   # No CloudFormation stack exists, but the backend records both fields on the
#   # scanner_regions[] entry and the console reads them.
#   stack_id     = "terraform"
#   stack_region = local.region
#
#   depends_on = [
#     aws_cloudwatch_event_target.daily,
#     aws_iam_role_policy.task,
#     aws_iam_role_policy.orchestrator,
#   ]
# }
