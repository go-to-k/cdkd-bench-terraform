#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { WebAppStack } from '../lib/web-app-stack.ts';
import { WideStack } from '../lib/wide-stack.ts';
import { ServerlessStack } from '../lib/serverless-stack.ts';
import { CloudFrontStack } from '../lib/cloudfront-stack.ts';
import { Ec2Stack } from '../lib/ec2-stack.ts';
import { EcsStack } from '../lib/ecs-stack.ts';

const app = new cdk.App();
const env = { region: process.env.AWS_REGION ?? 'us-east-1' };

// BENCH_SUFFIX makes every stack name unique per benchmark run, which makes
// every run measure the COLD path.
//
// Why this exists: re-creating an IAM instance profile under a name that was
// used before is roughly 5x faster to propagate to EC2 than a name AWS has
// never seen (measured: 7.9s median cold vs 1.5s median warm). A benchmark
// that redeploys one fixed stack name therefore measures a warmed-up AWS from
// run 2 onward. That is not neutral between tools: cdkd waits for the actual
// propagation, so it gets faster as the name warms, while Terraform pays a
// fixed wait inside `aws_iam_instance_profile` and does not. Reusing names
// silently handed cdkd a ~6s advantage that a real first deploy never sees.
//
// A first deploy of a new stack is the honest comparison, so the harness
// passes a fresh suffix for every run of every tool.
const suffix = (process.env.BENCH_SUFFIX ?? '').replace(/[^A-Za-z0-9]/g, '');
const id = (base: string) => `${base}${suffix}`;

// Main stacks (deployed by cdkd / cdk / terraform). No explicit physical names,
// so cdkd and cdk generate distinct names and never collide.
new WebAppStack(app, id('BenchWebApp'), { env });
new WideStack(app, id('BenchWide'), { env });
new ServerlessStack(app, id('BenchServerless'), { env });
new CloudFrontStack(app, id('BenchCloudFront'), { env });
new Ec2Stack(app, id('BenchEc2'), { env });
new EcsStack(app, id('BenchEcs'), { env });

// `*Nw` twins are deployed by the `cdkd --no-wait` tool ONLY. Distinct stack
// name => distinct cdkd-generated resource names, so measuring cdkd and
// cdkd --no-wait back-to-back does NOT collide on the SQS 60s name-reuse
// cooldown (which would otherwise inflate the --no-wait number).
new WebAppStack(app, id('BenchWebAppNw'), { env });
new WideStack(app, id('BenchWideNw'), { env });
new ServerlessStack(app, id('BenchServerlessNw'), { env });
new CloudFrontStack(app, id('BenchCloudFrontNw'), { env });
new Ec2Stack(app, id('BenchEc2Nw'), { env });
new EcsStack(app, id('BenchEcsNw'), { env });

// `*Fw` twins are deployed by the `cdkd --full-wait` tool ONLY, for the same
// name-collision reason: the ecs scenario's ALB is deleted asynchronously, so
// reusing one stack for the default and --full-wait runs risks a
// DuplicateLoadBalancerName on the second create.
new EcsStack(app, id('BenchEcsFw'), { env });
