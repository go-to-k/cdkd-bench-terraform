#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { WebAppStack } from '../lib/web-app-stack.ts';
import { WideStack } from '../lib/wide-stack.ts';
import { ServerlessStack } from '../lib/serverless-stack.ts';
import { CloudFrontStack } from '../lib/cloudfront-stack.ts';

const app = new cdk.App();
const env = { region: process.env.AWS_REGION ?? 'us-east-1' };

// Main stacks (deployed by cdkd / cdk / terraform). No explicit physical names,
// so cdkd and cdk generate distinct names and never collide.
new WebAppStack(app, 'BenchWebApp', { env });
new WideStack(app, 'BenchWide', { env });
new ServerlessStack(app, 'BenchServerless', { env });
new CloudFrontStack(app, 'BenchCloudFront', { env });

// `*Nw` twins are deployed by the `cdkd --no-wait` tool ONLY. Distinct stack
// name => distinct cdkd-generated resource names, so measuring cdkd and
// cdkd --no-wait back-to-back does NOT collide on the SQS 60s name-reuse
// cooldown (which would otherwise inflate the --no-wait number).
new WebAppStack(app, 'BenchWebAppNw', { env });
new WideStack(app, 'BenchWideNw', { env });
new ServerlessStack(app, 'BenchServerlessNw', { env });
new CloudFrontStack(app, 'BenchCloudFrontNw', { env });
