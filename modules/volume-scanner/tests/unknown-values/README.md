# Unknown-value regression harness

`terraform test` can only supply **known** values through `variables`, so it
cannot reproduce the one failure mode this module has shipped twice:

> `subnet_ids` and `vpc_id` come from resources created in the same apply, so
> their values are unknown at plan while the list LENGTH is known. Any
> for-expression carrying an `if` predicate over those values becomes wholly
> unknown, which makes the index-keyed `byo_subnets` map unknown and fails every
> bring-your-own validation with `Invalid for_each argument`.

Reproducing it needs a **root module** that builds a VPC and subnets and feeds
their attributes in — which is what this directory is. It is not picked up by the
module's own `terraform test` run.

```bash
cd tests/unknown-values
terraform init -backend=false
terraform test
```

Run it after any change to `local.byo_subnet_ids`, `local.byo_vpc_id`,
`local.byo_subnets`, or the data sources keyed off them.
