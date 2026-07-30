# cdkd-bench-terraform

Deploy-speed benchmark of the same stack, expressed six ways, across three tools:

| Tool | How it provisions |
|---|---|
| **cdkd** | Direct AWS SDK / Cloud Control API, no CloudFormation |
| **CDK (CloudFormation)** | `cdk deploy` -> CloudFormation change set |
| **Terraform** | `terraform apply` -> direct AWS APIs |

The interesting race is **cdkd vs Terraform**: both talk straight to AWS APIs,
so this isolates orchestration (DAG parallelism, polling, SDK vs CC-API) rather
than the CloudFormation tax. CloudFormation is included as the slow baseline.

## Scenarios

| Scenario | Shape | CDK | Terraform |
|---|---|---|---|
| `webapp` | VPC + NAT + subnets + gateway endpoints + DDB + SQS + S3 + Lambda x2 + HTTP API | `cdk/lib/web-app-stack.ts` | `terraform/main.tf` |
| `wide` | 48 independent resources (S3/DDB/SQS/SNS/SSM/Logs x8 each) | `cdk/lib/wide-stack.ts` | `terraform/wide/` |
| `serverless` | Lambda x3 + HTTP API + DDB + SNS/SQS + EventBridge | `cdk/lib/serverless-stack.ts` | `terraform/serverless/` |
| `cloudfront` | S3 origin + CloudFront + OAC | `cdk/lib/cloudfront-stack.ts` | `terraform/cloudfront/` |
| `ec2` | VPC (1 AZ, public) + SG + IAM Role + InstanceProfile + t3.micro x3 + EBS | `cdk/lib/ec2-stack.ts` | `terraform/ec2/` |
| `ecs` | VPC (2 AZ, public) + ECS Cluster + Fargate TaskDef + Service + ALB + TG + Listener | `cdk/lib/ecs-stack.ts` | `terraform/ecs/` |

Each pair is kept resource-for-resource equivalent (best effort), including
counts: `terraform/ec2/` creates one InstanceProfile per instance because CDK's
L2 `ec2.Instance` does, even though a Terraform user would normally share one.

### Completion definitions

Deploy speed is only comparable between tools that mean the same thing by
"done". The tool names encode three definitions:

| Tool argument | Meaning |
|---|---|
| `cdkd-nowait` / `tf-nowait` | fire and forget: return without waiting for the dominant resource to become usable |
| `cdkd` / `tf` / `cfn` | each tool's own default |
| `cdkd-fullwait` / `tf-fullwait` | wait until the resource is fully in service |

A tool with no distinct mode for a scenario is reported as `N/A` **with the
reason**, never silently omitted, so "cannot do this" stays distinguishable
from "was not measured". Examples: `aws_instance` has no wait opt-out, so the
`ec2` fire-and-forget column is cdkd-only; `aws_cloudfront_distribution` does
(`wait_for_deployment = false`), so `cloudfront` has both.

### Why Lambda is not in the VPC (webapp)

Lambda-in-VPC attaches a Hyperplane ENI whose detach on destroy can take
20-40 min, which would wreck repeatable iteration. The VPC/NAT/endpoints are
still provisioned (and timed), but they tear down cleanly in ~1-2 min. A
`lambda-in-vpc` variant can be added later if that path is worth measuring.

## Prerequisites

- AWS credentials (`aws sts get-caller-identity` works)
- Node.js >= 20, `terraform` on PATH
- cdkd built: `cd ../cdkd && vp run build  # clone cdkd as a sibling dir` -> `dist/cli.js`

## Run

```bash
# default tools (cdkd,cdkd-nowait,cfn,tf), default scenario (webapp)
./scripts/run-benchmark.sh

# pick tools and scenario
./scripts/run-benchmark.sh cdkd,tf ec2
./scripts/run-benchmark.sh cdkd,cdkd-fullwait,cfn,tf,tf-fullwait ecs
./scripts/run-benchmark.sh cdkd-nowait,tf-nowait cloudfront

# options via env
AWS_REGION=us-east-1 RUNS=3 ./scripts/run-benchmark.sh
```

**Point `CDKD_BIN` at the binary you mean to measure.** It defaults to a sibling
`../cdkd/dist/cli.js`, which is usually the last release rather than the tree
under test — nothing errors, you just get plausible numbers for the wrong
build. Every results file records the resolved path, branch and commit so a run
can never be misattributed after the fact.

```bash
export CDKD_BIN=/path/to/cdkd/dist/cli.js
node "$CDKD_BIN" --version && node "$CDKD_BIN" deploy --help | grep -- --full-wait
```

Each tool is deployed cold (destroy -> deploy -> destroy). One-time setup
(`npm install`, `cdk bootstrap`, `terraform init`, provider downloads) runs
up-front and is **not** timed. The measured number is the single end-to-end
deploy command wall-time.

Results are written to `results/results-<timestamp>.md`.

## Fairness notes

- Terraform `init` and CDK `bootstrap` are one-time and excluded, mirroring how
  each tool is used day to day.
- `terraform apply` includes its own plan; `cdk/cdkd deploy` include their own
  synth. The end-to-end deploy wall-time is the apples-to-apples number; synth
  is also reported separately for cdk/cdkd.
- All resources use auto-generated / prefixed names, so the three tools never
  collide and can be run in any subset.
