import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { AttributeType, BillingMode, Table } from 'aws-cdk-lib/aws-dynamodb';
import { Queue } from 'aws-cdk-lib/aws-sqs';
import { Topic } from 'aws-cdk-lib/aws-sns';
import { Bucket, BlockPublicAccess, BucketEncryption } from 'aws-cdk-lib/aws-s3';
import { StringParameter } from 'aws-cdk-lib/aws-ssm';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';

/**
 * A "parallel-wide" stack: many INDEPENDENT resources, no NAT / no long
 * dependency chain. This isolates orchestration throughput (DAG parallelism +
 * per-resource API overhead) rather than a single slow serial AWS resource,
 * so tool differences are not compressed by a shared wait floor.
 *
 * Kept equivalent to terraform/wide/main.tf. Count is set via WIDE_COUNT env
 * (default 8 of each type).
 */
export class WideStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const n = Number(process.env.WIDE_COUNT ?? '8');

    for (let i = 0; i < n; i++) {
      new Bucket(this, `Bucket${i}`, {
        blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
        encryption: BucketEncryption.S3_MANAGED,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: false,
      });
      new Table(this, `Table${i}`, {
        partitionKey: { name: 'id', type: AttributeType.STRING },
        billingMode: BillingMode.PAY_PER_REQUEST,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });
      new Queue(this, `Queue${i}`, {
        retentionPeriod: cdk.Duration.days(4),
      });
      new Topic(this, `Topic${i}`);
      new StringParameter(this, `Param${i}`, {
        stringValue: `bench-wide-${i}`,
      });
      new LogGroup(this, `LogGroup${i}`, {
        retention: RetentionDays.ONE_WEEK,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });
    }
  }
}
