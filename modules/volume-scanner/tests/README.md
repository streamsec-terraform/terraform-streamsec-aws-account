# volume-scanner tests

```bash
terraform test
```

Mock providers throughout, no AWS API calls. Requires Terraform >= 1.7 for `mock_provider`, stricter than the module's own `required_version` of 1.3.

## The one case `terraform test` cannot cover

Tests can only supply **known** values through `variables`, so they cannot reproduce the failure this module has shipped twice against a green suite: when `vpc_id`/`subnet_ids` come from resources created in the same apply, their values are unknown at plan while the list **length** is known, and any for-expression with an `if` predicate over them becomes wholly unknown — making the index-keyed `byo_subnets` map unknown and failing every bring-your-own validation with `Invalid for_each argument`.

After any change to `local.byo_vpc_id`, `local.byo_subnet_ids`, `local.byo_subnets`, or the data sources keyed off them, plan a throwaway root module. It must succeed; `Invalid for_each argument` means a filter has been reintroduced.

```hcl
resource "aws_vpc" "t" { cidr_block = "10.60.0.0/16" }

resource "aws_subnet" "private" {
  count      = 2                     # length known at plan, ids are not
  vpc_id     = aws_vpc.t.id
  cidr_block = cidrsubnet("10.60.0.0/16", 8, count.index)
}

module "scanner" {
  source             = "../.."
  customer_id        = "your-workspace-id"
  create_scanner_vpc = false
  vpc_id             = aws_vpc.t.id
  subnet_ids         = aws_subnet.private[*].id
}
```
