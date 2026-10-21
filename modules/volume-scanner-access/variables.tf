variable "hub_account_id" {
  description = "Stream Security id of the hub: the integrated AWS account whose volume scanner scans this one (streamsec_aws_account's id, not the 12-digit AWS account id)."
  type        = string
  nullable    = false

  validation {
    condition     = trimspace(var.hub_account_id) != ""
    error_message = "hub_account_id must not be blank: set it to the Stream Security id of the hub account (the id of its streamsec_aws_account)."
  }
}

variable "tags" {
  description = "A map of additional tags to add to the IAM role"
  type        = map(string)
  default     = {}
  nullable    = false
}
