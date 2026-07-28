# Benchmark results: cdkd vs Terraform vs CloudFormation

The same logical stack, expressed in CDK (deployed with `cdkd` and with
`cdk deploy`) and in Terraform, compared on deploy speed.

## Method

- Metric: **cold end-to-end deploy wall-time, median of 3 runs**.
- One-time setup (`npm install`, `cdk bootstrap`, `terraform init`, provider
  download) is done in advance and **not** counted.
- Region us-east-1 (CloudFront is global, so the cloudfront scenario is
  effectively region-independent).
- cdkd version: includes the polling fixes from PR #1175 / #1177 (v0.260.x).
- Units are seconds. **Bold** marks the fastest tool for that scenario.
- **Every row compares tools whose completion definition matches.** Where a tool
  offers both a waiting and a non-waiting mode for the resource that dominates
  the scenario, both are measured. Where it offers only one, the table says
  `N/A` rather than leaving the cell blank, so that "cannot do this" stays
  distinguishable from "was not measured".

### What "done" means, per tool

cdkd is template-compatible with CloudFormation but deliberately **not**
wait-semantics-identical: the completion definition is decided per resource
type and documented (`docs/cli-reference.md` in the cdkd repo has the full
table). Where CloudFormation and Terraform agree, cdkd matches them. Where they
disagree, cdkd's default takes the definition that suits dev/test iteration and
`--full-wait` opts into the CloudFormation one.

That cuts both ways, and this table shows both directions:

- **It made cdkd slower on ALB-bearing stacks.** cdkd used to return as soon as
  `CreateLoadBalancer` returned, while CloudFormation and Terraform both wait
  for the load balancer to reach `active`. cdkd now waits too, which costs
  90-180s on any stack with an ALB. The ecs row below pays it.
- **It kept cdkd fast on ECS Services.** CloudFormation waits for steady state;
  Terraform's `wait_for_steady_state` defaults to false. cdkd keeps the
  fire-and-forget default and offers `--full-wait` as the opt-in, which is the
  same choice Terraform gives its users.

## Summary

| Scenario | Shape | cdkd | cdkd `--no-wait` | Terraform | CloudFormation |
|---|---|---:|---:|---:|---:|
| **wide** | 48 independent resources (S3/DDB/SQS/SNS/SSM/Logs x8 each) | **25.4** | 25.3 | 50.4 | 85.9 |
| **serverless** | Lambda x3 + HTTP API + DDB + SNS/SQS + EventBridge | **31.4** | 31.8 | 57.9 | 124.2 |
| **webapp** | VPC + NAT + subnets + gateway endpoints + DDB + SQS + S3 + Lambda x2 + HTTP API | 127.0 | **32.4** | 127.8 | 161.9 |
| **cloudfront** | S3 origin + CloudFront + OAC | **171.2** | 17.8 | 191.1 | 208.1 |

> **The cdkd column was verified on v0.260.10** (which includes the #1181
> deploy-overhead optimization). The Terraform and CloudFormation columns are
> carried over, since neither depends on the cdkd binary.
>
> - **wide**: re-measured cleanly on v0.260.10, 26.0 to **25.4s** (about 0.6s faster).
> - **serverless / webapp / cloudfront**: also re-measured on v0.260.10, but the
>   fixed-cost saving (about 1.7s per deploy) is **smaller than run-to-run
>   variance** on these provisioning-bound stacks. For example cloudfront came
>   out at 173.9 vs the original 171.2, which is within the noise of CloudFront
>   propagation. The original clean values are therefore kept. The optimization
>   shows up on small, single-resource iteration instead.
> - Note: an earlier attempt ran these scenarios **concurrently**, which inflated
>   the numbers (webapp 127 to 136s, for example). Those contaminated values were
>   discarded; only clean values measured in isolation are reported.

## Per-run detail (median / all runs)

| Scenario | Tool | median | all runs |
|---|---|---:|---|
| webapp | cdkd | 127.0 | 113 / 141 / 127 |
| webapp | Terraform | 127.8 | 128 / 159 / 118 |
| webapp | CloudFormation | 161.9 | 162 / 158 / 164 |
| webapp | cdkd --no-wait | 32.4 | 29.1 / 32.4 / 33.4 |
| cloudfront | cdkd | 171.2 | 171.2 / 184.8 / 163.1 |
| cloudfront | Terraform | 191.1 | 182.5 / (1996.8, Terraform-side hang, excluded) / 191.1 |
| cloudfront | CloudFormation | 208.1 | 200.8 / 208.1 / 232.4 |
| cloudfront | cdkd --no-wait | 17.8 | 15.0 / 17.8 / 18.2 |

## Scenario notes

- **wide (cdkd fastest, about 2x Terraform and 3.3x CloudFormation)**: on a wide,
  highly parallel stack, cdkd's DAG plus direct SDK calls win clearly and with
  low variance.
- **serverless (cdkd fastest, about 1.8x Terraform and 4x CloudFormation)**: there
  are real dependency chains but no slow resources, so cdkd wins the same way it
  does on wide. `--no-wait` makes no difference here (nothing to skip).
- **webapp (cdkd and Terraform are a genuine tie, 0.8s apart)**: the NAT Gateway
  (about 90 to 120s) is a floor every tool pays, which compresses the difference.
  Neither cdkd nor Terraform can win against physics on its own. Only `--no-wait`,
  which skips the NAT stabilization wait, lands in a different league at 32.4s.
- **cloudfront (cdkd beats Terraform)**: CloudFront propagation (180s+, high
  variance) dominates. After the polling fixes, cdkd's 171.2s beats Terraform's
  ~186s (excluding the hung run) and CloudFormation's 208.1s, so cdkd < TF < CFn.
  `--no-wait` is 17.8s (15.0 / 17.8 / 18.2) because it skips the propagation wait.

## Conclusions, honestly

- **The winner depends on the shape of the stack.** Parallel-shaped stacks (wide,
  serverless) are a clear cdkd win. Stacks dominated by a single slow resource
  (webapp's NAT, cloudfront's propagation) are governed by physics, so the result
  is a tie or a narrow margin. Only choosing not to wait (`--no-wait`) beats physics.
- **"cdkd is faster at everything" is not true.** webapp is a genuine tie with Terraform.
- Across all three engines, CloudFormation is consistently the slowest.

## Side effect: this benchmark actually made cdkd faster (PR #1175 / #1177)

Digging into why cdkd was losing to Terraform on webapp surfaced **four real
deploy-speed bugs, all since fixed**:

1. **Longest-pole scheduling**: the ready set was ordered by template logical id.
   An EIP with no dependencies was scheduled late, which delayed the NAT Gateway
   (the long pole) behind it. Ordering by transitive dependency count instead took
   a fast webapp run from 154s to 112s.
2. **EIP SDK provider**: the EIP went through the Cloud Control API, whose async
   polling backoff cost about 23s for a resource AWS allocates instantly. A native
   EC2 SDK provider (AllocateAddress) brought it to about 2.4s.
3. **NAT polling interval**: the SDK waiter's default backoff (`minDelay: 15s`,
   `maxDelay: 120s`) was far too sparse, delaying detection of "available" by up
   to about 2 minutes. Overriding it to `minDelay: 5, maxDelay: 15` moved webapp
   from a loss (190s) to a tie (127s).
4. **CloudFront polling interval**: a hand-written wait loop capped its backoff at
   30s. Lowering the cap to 10s turned cloudfront from a loss into a win.

Four fixes shipped in #1175; a repo-wide sweep found the same pattern in seven more
providers and shipped as #1177 (10s caps, a mechanical non-regression test, and
verification against real AWS). **The benchmark did not just rank the tools, it made
cdkd faster.**

## Reproducing

```bash
./scripts/run-benchmark.sh cdkd,cdkd-nowait,cfn,tf wide   # or webapp / serverless / cloudfront
RUNS=3 ./scripts/run-benchmark.sh cdkd,tf webapp
```

- Raw logs: `results/results-<scenario>-<ts>.md`
  - Every file records **the cdkd version it measured** in its header. Runs on
    `0.260.7` and earlier predate the polling fixes (#1175 / #1177) and include
    runs where cdkd loses to Terraform (these are the "before" side of the section
    above). The summary table is measured on `0.260.10` and later. Raw data from
    both sides is kept, so the before/after is verifiable from this directory
    rather than only from the summary.
- CDK: `cdk/lib/*-stack.ts`. Terraform: `terraform/<scenario>/`.

## Caveats (for credibility)

- Parity adjustments: CDK's `restrictDefaultSecurityGroup` custom resource and
  CDK-managed LogGroups are disabled, so cdkd and CloudFormation are not carrying
  resources Terraform does not have. On serverless, the Terraform configuration
  was corrected to grant the consumer Lambda the SQS receive permission that the
  CDK `SqsEventSource` adds automatically.
- `terraform apply` includes its own plan, and `cdk` / `cdkd deploy` include their
  own synth. End-to-end wall-time is the apples-to-apples number.
- NAT and CloudFront timings vary with actual AWS provisioning time, hence median
  of 3.
- SQS has a 60s name-reuse cooldown. That is an AWS constraint, not a tool defect.
- cdkd is experimental and intended for dev/test workflows.
