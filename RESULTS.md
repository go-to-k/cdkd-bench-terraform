# Benchmark results: cdkd vs Terraform vs CloudFormation

The same logical stack, expressed in CDK (deployed with `cdkd` and with
`cdk deploy`) and in Terraform, compared on deploy speed.

## Method

- Metric: **cold end-to-end deploy wall-time, median of 7 runs**.
- **Every scenario gets the same 7 runs**, and every individual run is listed
  below. A per-scenario run count would have to be justified, and any rule for
  choosing it invites the question of whether it was chosen after seeing the
  results; one number for everything removes the question. It is not a
  formality either: at n=3 the cloudfront gap read 14.5s and the serverless
  ratio read 2.8x, and both shrank materially once the remaining runs landed.
- One-time setup (`npm install`, `cdk bootstrap`, `terraform init`, provider
  download) is done in advance and **not** counted.
- Region us-east-1 (CloudFront is global, so the cloudfront scenario is
  effectively region-independent).
- Every number here comes from ONE cdkd binary in one measurement campaign.
- Units are seconds. **Bold** marks the fastest tool for that scenario.
- **A median gap only counts when the two run distributions actually
  separate.** Reported per row below as either "separated" (no cdkd run
  overlaps any Terraform run; exact Mann-Whitney p = 0.0006, the floor at
  n=7 vs n=7) or "overlapping" (the ranges intersect, so n=7 cannot tell the
  two apart whatever the medians say).

  Judging by the size of the median gap instead does not work, and gets it
  wrong in both directions here: ec2 separates completely on a 6.8s gap
  (slowest cdkd run 32.9s, fastest Terraform run 35.7s), while webapp's much
  larger 17.6s gap sits inside two heavily overlapping ranges and is NOT
  distinguishable (p = 0.24). Raw seconds are the wrong unit; NAT-gateway
  variance swamps a bigger gap than EC2-instance variance does a smaller one.

  "Overlapping" means unproven at this sample size, not disproven. Re-running
  the same scenario with the same binary hours later also moved the cdkd
  median by 1.1s on wide and 4.5s on serverless, so sub-second precision is
  not on offer anywhere.
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

### Every run is a first deploy (and why that had to be fixed)

Every run of every tool now gets resource names AWS has never seen. cdkd and
`cdk` read `BENCH_SUFFIX`; Terraform gets `-var prefix=`. Earlier rounds
redeployed one fixed stack name, and that turned out to be measuring something
other than what it claimed.

Re-creating an IAM instance profile under a name AWS has seen before
propagates to EC2 roughly **5x faster** than a fresh one. Measured directly,
using `run-instances --dry-run` as the readiness probe (it validates the
instance profile and returns the same `Invalid IAM Instance Profile name`
error a real launch does, so no instances need to be started):

| | median | runs |
|---|---:|---|
| fresh name each time | **7.91s** | 8.05 / 6.91 / 7.91 / 8.99 / 6.90 |
| one name, deleted and recreated | **1.49s** | 8.07 / 1.46 / 1.49 / 1.45 / 3.61 |

The first warm run still pays the full cold cost; runs 2+ collapse.

This is not neutral between tools. cdkd waits for the propagation to actually
finish, so it gets faster as a name warms up. Terraform pays a fixed ~7-8s
inside `aws_iam_instance_profile` whether the name is warm or cold (measured
at 7-8s in both conditions). **Fixed names therefore handed cdkd an advantage
that no first deploy ever sees.**

The ec2 row showed the symptom before the cause was known: across 7 fixed-name
runs cdkd fell 43.7 -> 28.4s with Spearman rho **-0.86** against run index,
while Terraform (-0.25) and CloudFormation (+0.29) stayed flat. Re-measured
with fresh names the trend is gone (rho **+0.71**, i.e. mildly the other way),
which is the check that the diagnosis was right rather than merely plausible.

Fixed names are a legitimate thing to measure -- they are the repeat-deploy CI
loop -- and `COLD=0` still does it. They are just not a first deploy, and this
document reports first deploys.

## Summary

| Scenario | Shape | cdkd | cdkd `--no-wait` | Terraform | CloudFormation | vs Terraform |
|---|---|---:|---:|---:|---:|---|
| **wide** | 48 independent resources (S3/DDB/SQS/SNS/SSM/Logs x8 each) | **20.0** | 21.1 | 46.1 | 89.1 | 2.31x, separated |
| **serverless** | Lambda x3 + HTTP API + DDB + SNS/SQS + EventBridge | **25.9** | 24.6 | 57.5 | 127.1 | 2.22x, separated |
| **ec2** | VPC + subnet + SG + IAM role + EC2 instance x3 (t3.micro + EBS) | **29.1** | 22.0 | 35.9 | 193.9 | 1.23x, separated |
| **webapp** | VPC + NAT + subnets + gateway endpoints + DDB + SQS + S3 + Lambda x2 + HTTP API | 109.7 | 23.4 | 127.3 | 166.1 | median favours cdkd, overlapping |
| **ecs** | VPC 2AZ + Fargate cluster/task/service + ALB + target group | **162.8** | 34.5 | 209.5 | 276.7 | 1.29x, separated |
| **cloudfront -- created (fire and forget)** | S3 origin + CloudFront + OAC | 11.1 | 10.4 | 10.3 (`wait_for_deployment=false`) | no such mode | tie |
| **cloudfront -- `Deployed`** | S3 origin + CloudFront + OAC | 174.0 (`--full-wait`) | n/a | 166.4 | 232.3 | tie |

The cloudfront scenario became two rows on 2026-07-31: cdkd >= 0.271
(go-to-k/cdkd#1282) flipped its default completion for
`AWS::CloudFront::Distribution` to fire-and-forget, so the tools' DEFAULTS no
longer share a completion definition there. Each row holds every tool to the
same definition; a cell outside a tool's default names the selecting flag.
Both cloudfront rows were re-measured in one interleaved campaign on cdkd
0.272.0 (all six modes, same 7-run rule); the other scenarios' numbers are
from the original campaign.

cdkd is clearly faster than Terraform in four of the six scenarios -- wide
2.31x, serverless 2.22x, ecs 1.29x, ec2 1.23x, each with completely separated
run distributions. Of the remaining two, webapp's median favours cdkd by
17.6s but its runs overlap Terraform's too much for n=7 to separate them, and
cloudfront is a tie in BOTH completion definitions (0.8s apart fire-and-forget,
7.6s apart with fully overlapping runs on `Deployed`). **No scenario is
slower.** Against CloudFormation cdkd is faster everywhere, by 1.3x to 4.9x
(the `Deployed`-definition cloudfront pair, 174.0 vs 232.3, is the 1.3x
floor).

The pattern is the point: **cdkd's lead is largest where the wall-clock is
dominated by orchestration, and vanishes where it is dominated by AWS-side
physical provisioning.** wide and serverless are almost pure orchestration and
cdkd runs 2.2-2.3x faster; cloudfront is almost pure propagation delay and the
two tools land 2.8s apart, which this document treats as a tie. Nothing here
makes AWS itself faster, and a benchmark that claimed otherwise would be wrong.

### Matched completion definitions

The comparison above puts each tool in its DEFAULT mode, and the two tools do
not define "done" identically everywhere. Where both offer the same
definition explicitly, here they are compared directly:

| Comparison | cdkd | Terraform |
|---|---:|---:|
| ecs, both waiting for a steady service (`--full-wait` vs `wait_for_steady_state=true`) | **227.7** | 282.7 |
| cloudfront, neither waiting for propagation (cdkd default / `--no-wait` vs `wait_for_deployment=false`) | 11.1 / 10.4 | 10.3 |
| cloudfront, both waiting for `Deployed` (`--full-wait` vs Terraform default) | 174.0 | 166.4 |

The ecs row is the one that matters most for reading the rest of this
document: with the completion definition held identical, cdkd is still 1.24x
faster. Whatever the default-mode numbers show, they are not an artifact of
cdkd waiting for less.

Both cloudfront rows are ties. Fire-and-forget is 0.8s apart on samples that
span 9.9-27.9s and 9.9-12.1s; `Deployed` is 7.6s apart on 163.7-216.6s vs
155.7-188.4s -- fully overlapping ranges that n=7 cannot separate. Per the
noise rule in Method, single-digit-second gaps are ties regardless of
direction. (Since go-to-k/cdkd#1282 the cloudfront summary rows above ARE
these matched pairs -- the scenario's defaults no longer share a definition,
so the two-row summary and this table say the same thing.)

## Per-run detail (median / all runs)

| Scenario | Tool | median | all runs |
|---|---|---:|---|
| wide | cdkd | 20.0 | 19.2 / 20.0 / 19.7 / 21.1 / 19.7 / 21.0 / 20.6 |
| wide | cdkd --no-wait | 21.1 | 20.3 / 23.8 / 21.5 / 21.7 / 21.1 / 19.2 / 20.9 |
| wide | CloudFormation | 89.1 | 89.3 / 89.1 / 89.1 / 88.1 / 94.4 / 94.3 / 88.3 |
| wide | Terraform | 46.1 | 43.6 / 50.1 / 46.1 / 46.4 / 41.4 / 57.6 / 45.5 |
| serverless | cdkd | 25.9 | 20.6 / 26.1 / 21.5 / 26.2 / 25.9 / 24.8 / 27.4 |
| serverless | cdkd --no-wait | 24.6 | 24.2 / 25.6 / 23.5 / 24.6 / 26.8 / 24.6 / 21.4 |
| serverless | CloudFormation | 127.1 | 127.8 / 127.2 / 127.1 / 127.1 / 127.1 / 127.0 / 127.1 |
| serverless | Terraform | 57.5 | 72.0 / 61.1 / 57.6 / 57.4 / 57.5 / 57.5 / 57.5 |
| ec2 | cdkd | 29.1 | 28.3 / 28.1 / 28.3 / 30.3 / 29.8 / 32.9 / 29.1 |
| ec2 | cdkd --no-wait | 22.0 | 21.9 / 21.9 / 22.0 / 22.4 / 22.0 / 21.9 / 22.0 |
| ec2 | CloudFormation | 193.9 | 193.5 / 188.2 / 188.0 / 193.9 / 199.0 / 199.5 / 193.9 |
| ec2 | Terraform | 35.9 | 35.9 / 36.3 / 35.9 / 36.3 / 35.8 / 35.9 / 35.7 |
| webapp | cdkd | 109.7 | 98.2 / 109.7 / 127.3 / 137.6 / 100.1 / 118.6 / 100.3 |
| webapp | cdkd --no-wait | 23.4 | 23.4 / 23.3 / 26.9 / 24.7 / 23.4 / 23.2 / 23.7 |
| webapp | CloudFormation | 166.1 | 182.4 / 143.7 / 154.7 / 177.1 / 149.1 / 166.1 / 194.7 |
| webapp | Terraform | 127.3 | 137.0 / 127.5 / 117.0 / 137.5 / 116.5 / 127.3 / 105.9 |
| ecs | cdkd | 162.8 | 162.4 / 162.8 / 180.8 / 162.2 / 160.0 / 163.3 / 163.7 |
| ecs | cdkd --no-wait | 34.5 | 34.7 / 34.3 / 34.5 / 34.6 / 34.4 / 34.6 / 34.4 |
| ecs | cdkd --full-wait | 227.7 | 226.5 / 217.7 / 227.7 / 290.1 / 229.1 / 217.8 / 249.9 |
| ecs | CloudFormation | 276.7 | 281.6 / 276.3 / 276.7 / 276.3 / 276.5 / 276.8 / 276.7 |
| ecs | Terraform | 209.5 | 211.8 / 203.1 / 212.6 / 199.3 / 219.5 / 209.3 / 209.5 |
| ecs | Terraform (wait for healthy) | 282.7 | 324.2 / 269.9 / 284.9 / 293.9 / 282.7 / 269.8 / 259.6 |
| cloudfront | cdkd | 11.1 | 27.9 / 11.1 / 11.2 / 11.8 / 10.5 / 9.9 / 10.5 |
| cloudfront | cdkd --no-wait | 10.4 | 9.8 / 10.1 / 10.4 / 11.0 / 10.7 / 9.9 / 10.5 |
| cloudfront | cdkd --full-wait | 174.0 | 163.7 / 164.0 / 163.9 / 174.0 / 216.6 / 174.4 / 184.6 |
| cloudfront | CloudFormation | 232.3 | 198.8 / 232.3 / 198.6 / 232.5 / 232.7 / 232.3 / 321.0 |
| cloudfront | Terraform | 166.4 | 166.4 / 176.3 / 188.4 / 165.8 / 155.7 / 176.1 / 166.1 |
| cloudfront | Terraform (no wait) | 10.3 | 10.3 / 10.6 / 12.1 / 9.9 / 9.9 / 10.0 / 10.9 |

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
- **cloudfront (a tie in both completion definitions)**: since cdkd >= 0.271
  (go-to-k/cdkd#1282) the scenario is two rows. Fire-and-forget (cdkd default
  11.1 / `--no-wait` 10.4 vs Terraform `wait_for_deployment=false` 10.3) is
  pure API accept on both sides. `Deployed` (cdkd `--full-wait` 174.0 vs
  Terraform default 166.4, CloudFormation 232.3) is dominated by CloudFront
  edge propagation (~160s+, high variance), a floor every tool pays; the 7.6s
  median gap sits inside fully overlapping ranges. cdkd's run-1 default
  outlier (27.9s vs the 9.9-11.8s tail) was not root-caused (the harness
  overwrites per-run logs); the median is unaffected either way.
- **ec2**: VPC (1 AZ, public only) + SecurityGroup + IAM Role + InstanceProfile +
  `t3.micro` x3 + EBS. No NAT — the webapp scenario already measures that floor
  and it would dominate everything else here. No ALB and no AutoScalingGroup:
  ASG completion differs across all three engines (Terraform waits for capacity
  by default, CloudFormation does not without a `CreationPolicy`), so no fair row
  exists for it. Three instances rather than one so the row carries a parallelism
  signal on top of the single-instance `running` floor. All three engines agree
  on the completion definition, and `aws_instance` has no wait opt-out, so the
  fire-and-forget column is cdkd-only.
- **ecs**: VPC (2 AZ, public only — an ALB requires two) + Cluster + Fargate
  TaskDefinition + Service + ALB + TargetGroup + Listener. The container image is
  a public registry image on both sides rather than a CDK asset build: CDK's
  `ContainerImage.fromAsset()` builds and pushes inside the deploy and Terraform
  has no native equivalent, so a registry image is the only construction where
  both tools do the same work. This is the first scenario where **both**
  completion definitions exist on **both** tools, so it is reported as two rows
  (see the ecs table below). The ALB's `active` wait is paid by every mode.

`--no-wait` is close to a no-op on **wide** and **serverless**: the resource
types it gates (CloudFront, RDS, ElastiCache, NAT Gateway, EC2 Instance, ELBv2,
Lambda MicrovmImage) do not appear in either stack, so the flag has almost
nothing to skip. The measured gap is under two seconds in both, against 154s on
cloudfront. That is the flag behaving as designed, not an anomaly.

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

## It happened again: the ec2 / ecs round found five more (cdkd 0.268)

Adding the `ec2` and `ecs` scenarios repeated the pattern. Every fix below was
found by a benchmark row coming out worse than expected, and every one was
verified against real AWS before being believed.

1. **Wait semantics were undefined** (cdkd#1274 / #1275 / #1277 / #1278). What
   "done" means was decided ad hoc per resource type and written down nowhere.
   Three concrete defects fell out: an ELBv2 load balancer was reported complete
   while still `provisioning` (so a downstream consumer got a `DNSName` that
   503s); `--no-wait` silently did nothing on any stack containing an EC2
   instance, making two benchmark columns measure the same thing; and the docs
   claimed default waiting matched CloudFormation, which was no longer true.
   The fix **made cdkd slower** — waiting for the load balancer to reach
   `active` costs 90-180s (measured: 156s) on any ALB-bearing stack. That is the
   correct behavior and it is the clearest evidence this policy is not
   reverse-engineered from desired numbers.
2. **A regression the wait work introduced** (cdkd#1279). Once `--no-wait`
   genuinely skipped the `running` wait, cdkd's post-launch IAM instance profile
   check ran against a `pending` instance, and AWS rejects
   `AssociateIamInstanceProfile` for anything not `running`/`stopped`. Every CDK
   L2 `ec2.Instance` gets an instance profile, so `--no-wait` was broken for all
   of them. Found by this suite's `ec2` scenario, which is the first thing in the
   repo to deploy an L2-authored instance with a profile under `--no-wait`.
3. **SDK waiter poll caps** (same class as #1177, sites that sweep missed). The
   AWS SDK waiter picks each delay as
   `uniform_random(minDelay, min(minDelay * 2^(attempt-1), maxDelay))`, so the
   mean lag between "AWS reached the state" and "cdkd noticed" settles at
   maxDelay/2. #1177 tightened every hand-rolled poll loop to a 10s cap but could
   not see SDK waiter configs, and four sites kept 15s. Tightening the EC2
   Instance waiter cut both the median and the run-to-run spread sharply — the
   randomness in that formula was inflating variance as well as time.
4. **Deploy paid ~8.5s of fixed cost before the first resource** (cdkd#1283),
   dominated by 7 SEQUENTIAL AWS round trips against the state bucket (three
   `sts:GetCallerIdentity`, three `HeadBucket`, one `GetBucketLocation`). Two of
   the three STS calls were redundant, one `HeadBucket` re-asked a question
   answered moments earlier, and the two bucket-name probes were awaited one
   after the other. Now 3 round trips. This is proportionally worst on exactly
   the small, fast iterations cdkd is built for, so `wide` and `serverless`
   improved most.
5. **CloudFront Origin Access Control had no SDK provider**, so it fell through
   to the Cloud Control API and paid ProgressEvent polling — 2.3s on the critical
   path (the distribution references it) for a resource whose
   `CreateOriginAccessControl` returns immediately. Same shape as the #1175 EIP
   finding. `S3BucketOrigin.withOriginAccessControl()` is the standard way to
   write CloudFront + S3 in CDK, so this was costing every such user, not just a
   benchmark row.

A related fix landed in the benchmark harness itself: its log helpers wrote to
stdout from inside the command substitution that captures each timing, so a
failed run spliced `[ERROR]` into the number and crashed the formatter instead of
reporting the failure.

## On measurement noise, and what n=3 can and cannot decide

Two rows in this suite are dominated by AWS-side provisioning time that varies
more than the difference between the tools:

- **webapp** is governed by NAT gateway creation. Directly sampled twice in one
  session at 103.2s and 115.0s — a 12s spread from AWS alone. Across three runs
  one cdkd build spanned 17.4s and Terraform spanned 33s.
- **ec2** is governed by how long instances take to reach `running`, which also
  moves by tens of seconds between measurement windows.

With that much variance, **three runs cannot separate tools that are within
~10s of each other**, and a median drawn from three noisy samples is not
evidence of a win or a loss. This applies retroactively: an earlier published
webapp figure of 127.0s came from runs of 113 / 141 / 127, and calling that a
"genuine tie" was over-claiming from a sample too small to support it.

Where this matters, the run count is raised rather than the conclusion
strengthened, and rows that remain within noise are reported as such instead of
being resolved in whichever direction flatters cdkd.

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
  CDK `SqsEventSource` adds automatically. On ec2, `terraform/ec2/` creates one
  InstanceProfile **per instance** and on ecs `terraform/ecs/` creates one route
  table **per subnet**, because that is what the CDK constructs emit — a
  Terraform user would normally share one of each, but equal counts matter more
  here than idiomatic HCL.
- **Resource counts, exactly.** ec2 is 15 resources on both sides. ecs is 24 in
  CloudFormation terms vs 22 Terraform resources, and the gap is granularity,
  not work: CDK emits `AWS::EC2::VPCGatewayAttachment` and
  `AWS::EC2::SecurityGroupIngress` as standalone resources where Terraform folds
  the same two API calls into `aws_internet_gateway.vpc_id` and an inline
  `ingress` block. Both engines issue `AttachInternetGateway` and
  `AuthorizeSecurityGroupIngress` either way. Conversely CDK expresses the
  managed-policy attachment as an `AWS::IAM::Policy` where Terraform uses
  `aws_iam_role_policy_attachment` — one resource each. Splitting the Terraform
  side into separate `aws_vpc_internet_gateway_attachment` /
  `aws_security_group_rule` resources would equalize the count without changing
  a single API call, so it was not done.
- `terraform apply` includes its own plan, and `cdk` / `cdkd deploy` include their
  own synth. End-to-end wall-time is the apples-to-apples number.
- NAT and CloudFront timings vary with actual AWS provisioning time, hence median
  of 3.
- SQS has a 60s name-reuse cooldown. That is an AWS constraint, not a tool defect.
- cdkd is experimental and intended for dev/test workflows.
