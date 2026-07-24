import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import {
  GatewayVpcEndpointAwsService,
  IpAddresses,
  SubnetType,
  Vpc,
} from 'aws-cdk-lib/aws-ec2';
import {
  AttributeType,
  BillingMode,
  Table,
} from 'aws-cdk-lib/aws-dynamodb';
import { Queue } from 'aws-cdk-lib/aws-sqs';
import { Bucket, BlockPublicAccess, BucketEncryption } from 'aws-cdk-lib/aws-s3';
import {
  Architecture,
  Code,
  Function as LambdaFunction,
  Runtime,
} from 'aws-cdk-lib/aws-lambda';
import { SqsEventSource } from 'aws-cdk-lib/aws-lambda-event-sources';
import { HttpApi, HttpMethod } from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';

/**
 * A "typical web app" stack used to benchmark deploy speed across
 * cdkd / CDK (CloudFormation) / Terraform.
 *
 * Resource graph (kept intentionally equivalent to terraform/main.tf):
 *   - VPC (2 AZ) + 1 NAT Gateway + public/private subnets
 *   - S3 + DynamoDB Gateway VPC Endpoints (the VPC's purpose; delete cleanly)
 *   - DynamoDB table (on-demand)
 *   - SQS queue
 *   - S3 bucket
 *   - Lambda x2 (API handler + SQS consumer) -- intentionally NOT in the VPC
 *     to avoid Hyperplane-ENI detach lag on destroy (keeps iteration fast)
 *   - HTTP API (API Gateway v2) -> API handler
 *   - IAM roles (auto-created per Lambda)
 *
 * No explicit physical names are set, so CDK/cdkd auto-generate unique names
 * and sequential cdkd/CFn runs never collide.
 */
export class WebAppStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // --- Networking layer ---------------------------------------------------
    const vpc = new Vpc(this, 'Vpc', {
      ipAddresses: IpAddresses.cidr('10.0.0.0/16'),
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        { name: 'Public', subnetType: SubnetType.PUBLIC, cidrMask: 24 },
        {
          name: 'Private',
          subnetType: SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 24,
        },
      ],
    });

    vpc.addGatewayEndpoint('S3Endpoint', {
      service: GatewayVpcEndpointAwsService.S3,
    });
    vpc.addGatewayEndpoint('DynamoDbEndpoint', {
      service: GatewayVpcEndpointAwsService.DYNAMODB,
    });

    // --- Data layer ---------------------------------------------------------
    const table = new Table(this, 'Table', {
      partitionKey: { name: 'id', type: AttributeType.STRING },
      billingMode: BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const queue = new Queue(this, 'Queue', {
      visibilityTimeout: cdk.Duration.seconds(60),
      retentionPeriod: cdk.Duration.days(4),
    });

    const bucket = new Bucket(this, 'Bucket', {
      blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
      encryption: BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: false,
    });

    // --- Compute layer ------------------------------------------------------
    const apiFn = new LambdaFunction(this, 'ApiFn', {
      runtime: Runtime.NODEJS_22_X,
      architecture: Architecture.ARM_64,
      handler: 'index.handler',
      timeout: cdk.Duration.seconds(10),
      memorySize: 256,
      code: Code.fromInline(
        [
          "exports.handler = async (event) => {",
          "  return {",
          "    statusCode: 200,",
          "    headers: { 'Content-Type': 'application/json' },",
          "    body: JSON.stringify({ ok: true, table: process.env.TABLE_NAME }),",
          "  };",
          "};",
        ].join('\n'),
      ),
      environment: {
        TABLE_NAME: table.tableName,
        QUEUE_URL: queue.queueUrl,
        BUCKET_NAME: bucket.bucketName,
      },
    });
    table.grantReadWriteData(apiFn);
    queue.grantSendMessages(apiFn);
    bucket.grantReadWrite(apiFn);

    const consumerFn = new LambdaFunction(this, 'ConsumerFn', {
      runtime: Runtime.NODEJS_22_X,
      architecture: Architecture.ARM_64,
      handler: 'index.handler',
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      code: Code.fromInline(
        [
          "exports.handler = async (event) => {",
          "  for (const record of event.Records || []) {",
          "    console.log('msg', record.body);",
          "  }",
          "};",
        ].join('\n'),
      ),
      environment: { TABLE_NAME: table.tableName },
    });
    table.grantReadWriteData(consumerFn);
    consumerFn.addEventSource(new SqsEventSource(queue, { batchSize: 10 }));

    // --- API layer ----------------------------------------------------------
    const httpApi = new HttpApi(this, 'HttpApi', {
      apiName: 'bench-web-app',
    });
    httpApi.addRoutes({
      path: '/',
      methods: [HttpMethod.ANY],
      integration: new HttpLambdaIntegration('ApiIntegration', apiFn),
    });

    // --- Outputs ------------------------------------------------------------
    new cdk.CfnOutput(this, 'ApiUrl', { value: httpApi.apiEndpoint });
    new cdk.CfnOutput(this, 'TableName', { value: table.tableName });
    new cdk.CfnOutput(this, 'QueueUrl', { value: queue.queueUrl });
    new cdk.CfnOutput(this, 'BucketName', { value: bucket.bucketName });
  }
}
