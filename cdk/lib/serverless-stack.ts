import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { AttributeType, BillingMode, Table } from 'aws-cdk-lib/aws-dynamodb';
import { Queue } from 'aws-cdk-lib/aws-sqs';
import { Topic } from 'aws-cdk-lib/aws-sns';
import { SqsSubscription } from 'aws-cdk-lib/aws-sns-subscriptions';
import {
  Architecture,
  Code,
  Function as LambdaFunction,
  Runtime,
} from 'aws-cdk-lib/aws-lambda';
import { SqsEventSource } from 'aws-cdk-lib/aws-lambda-event-sources';
import { HttpApi, HttpMethod } from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import { Rule, Schedule } from 'aws-cdk-lib/aws-events';
import { LambdaFunction as LambdaTarget } from 'aws-cdk-lib/aws-events-targets';

/**
 * A "serverless" stack: Lambda x3 + HTTP API + DynamoDB + SNS/SQS + EventBridge.
 * No VPC / no NAT, so nothing is bottlenecked by a slow serial resource, but it
 * has real dependency CHAINS (Lambda -> API integration -> route; rule -> target
 * -> permission) — the band where longest-pole ready-set ordering matters.
 *
 * Kept equivalent to terraform/serverless/main.tf.
 */
export class ServerlessStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const inline = (body: string) =>
      Code.fromInline(
        `exports.handler = async (event) => { ${body} };`,
      );

    const table = new Table(this, 'Table', {
      partitionKey: { name: 'id', type: AttributeType.STRING },
      billingMode: BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const topic = new Topic(this, 'Topic');
    const queue = new Queue(this, 'Queue', {
      visibilityTimeout: cdk.Duration.seconds(60),
    });
    topic.addSubscription(new SqsSubscription(queue));

    const mk = (id: string, timeout = 10) =>
      new LambdaFunction(this, id, {
        runtime: Runtime.NODEJS_22_X,
        architecture: Architecture.ARM_64,
        handler: 'index.handler',
        timeout: cdk.Duration.seconds(timeout),
        memorySize: 256,
        code: inline("return { ok: true, table: process.env.TABLE_NAME };"),
        environment: { TABLE_NAME: table.tableName },
      });

    const apiFn = mk('ApiFn');
    const queueFn = mk('QueueFn', 30);
    const schedFn = mk('SchedFn');
    table.grantReadWriteData(apiFn);
    table.grantReadWriteData(queueFn);
    table.grantReadWriteData(schedFn);
    topic.grantPublish(apiFn);

    queueFn.addEventSource(new SqsEventSource(queue, { batchSize: 10 }));

    const httpApi = new HttpApi(this, 'HttpApi', { apiName: 'bench-serverless' });
    httpApi.addRoutes({
      path: '/',
      methods: [HttpMethod.ANY],
      integration: new HttpLambdaIntegration('ApiIntegration', apiFn),
    });

    new Rule(this, 'ScheduleRule', {
      schedule: Schedule.rate(cdk.Duration.hours(1)),
      targets: [new LambdaTarget(schedFn)],
    });

    new cdk.CfnOutput(this, 'ApiUrl', { value: httpApi.apiEndpoint });
    new cdk.CfnOutput(this, 'TableName', { value: table.tableName });
  }
}
