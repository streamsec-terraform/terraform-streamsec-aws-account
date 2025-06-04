################################################################################
# Stream Security AWS Account Variables
################################################################################

variable "streamsec_account" {
  description = "The AWS Account ID for the Stream.Security account."
  type        = string
  default     = "624907860825"
}

variable "response_policy_name" {
  description = "The name of the response policy"
  type        = string
  default     = "stream-security-response-policy"
}

variable "runbooks_prefix" {
  description = "The prefix for the runbooks"
  type        = string
  default     = ""
}

variable "response_role_name" {
  description = "The name of the response role"
  type        = string
  default     = "stream-security-response-role"
}

variable "exclude_runbooks" {
  description = "A list of runbooks to exclude from the response policy"
  type        = list(string)
  default     = []
}

################################################################################
# General
################################################################################

variable "tags" {
  description = "A map of global tags to add to all created resources"
  type        = map(string)
  default     = {}
}
