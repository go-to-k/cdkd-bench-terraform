# cdkd-bench-terraform

Deploy-speed benchmark of a **typical web-app stack** across three tools:

| Tool | How it provisions |
|---|---|
| **cdkd** | Direct AWS SDK / Cloud Control API, no CloudFormation |
| **CDK (CloudFormation)** | `cdk deploy` -> CloudFormation change set |
| **Terraform** | `terraform apply` -> direct AWS APIs |

The interesting race is **cdkd vs Terraform**: both talk straight to AWS APIs,
so this isolates orchestration (DAG parallelism, polling, SDK vs CC-API) rather
than the CloudFormation tax. CloudFormation is included as the slow baseline.

## The stack (equivalent across all three)

- VPC (2 AZ) + 1 NAT Gateway + public/private subnets
- S3 + DynamoDB Gateway VPC Endpoints
- DynamoDB table (on-demand), SQS queue, S3 bucket
- Lambda x2 (API handler + SQS consumer) — **intentionally not in the VPC**
- HTTP API (API Gateway v2) -> API handler
- IAM roles (one per Lambda)

`cdk/lib/web-app-stack.ts` (CDK) and `terraform/main.tf` (HCL) are kept
resource-for-resource equivalent (best effort).

### Why Lambda is not in the VPC

Lambda-in-VPC attaches a Hyperplane ENI whose detach on destroy can take
20-40 min, which would wreck repeatable iteration. The VPC/NAT/endpoints are
still provisioned (and timed), but they tear down cleanly in ~1-2 min. A
`lambda-in-vpc` variant can be added later if that path is worth measuring.

## Prerequisites

- AWS credentials (`aws sts get-caller-identity` works)
- Node.js >= 20, `terraform` on PATH
- cdkd built: `cd /Users/goto/pc/github/cdkd && vp run build` -> `dist/cli.js`

## Run

```bash
# all three
./scripts/run-benchmark.sh

# subset
./scripts/run-benchmark.sh cdkd,tf
./scripts/run-benchmark.sh cfn

# options via env
AWS_REGION=us-east-1 RUNS=3 ./scripts/run-benchmark.sh
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
