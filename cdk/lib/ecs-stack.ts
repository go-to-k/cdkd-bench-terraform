import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { IpAddresses, Peer, Port, SecurityGroup, SubnetType, Vpc } from 'aws-cdk-lib/aws-ec2';
import {
  Cluster,
  ContainerImage,
  FargateService,
  FargateTaskDefinition,
  LogDrivers,
} from 'aws-cdk-lib/aws-ecs';
import {
  ApplicationLoadBalancer,
  ApplicationProtocol,
  ApplicationTargetGroup,
  TargetType,
} from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';

/**
 * A "containerized service behind a load balancer" stack: VPC (1 AZ, public
 * only) + ECS Cluster + Fargate TaskDefinition + Service (desiredCount 1) +
 * ALB + TargetGroup + Listener.
 *
 * Why this shape (see cdkd-bench-terraform#4):
 *   - The container image is a PUBLIC registry image, not a
 *     `ContainerImage.fromAsset()` build. CDK's asset path builds and pushes to
 *     ECR inside the deploy and Terraform has no native equivalent, so a
 *     registry image is the only construction where both sides do the same
 *     work. It also removes image build time as a noise source.
 *   - No NAT gateway: the tasks run in public subnets with a public IP so they
 *     can pull the image, which keeps the ~90-120s NAT floor out of the row.
 *
 * This is the first scenario where BOTH completion definitions exist on BOTH
 * tools, so it is reported as two rows:
 *
 *   | Completion definition            | cdkd         | Terraform                            | CloudFormation |
 *   | Service ACTIVE (fire and forget) | default      | wait_for_steady_state = false (deflt) | N/A            |
 *   | Service steady state             | --full-wait  | wait_for_steady_state = true          | default        |
 *
 * CloudFormation has no fire-and-forget mode for a Service, so it appears only
 * in the second row. Putting it in the first would be exactly the mismatched
 * comparison the methodology rule in RESULTS.md prohibits.
 *
 * The ALB makes this row fair only from cdkd 0.268 onward: before that fix
 * cdkd returned as soon as `CreateLoadBalancer` returned, while Terraform and
 * CloudFormation both wait for the load balancer to reach `active`.
 *
 * Kept equivalent to terraform/ecs/main.tf.
 */
export class EcsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const vpc = new Vpc(this, 'Vpc', {
      ipAddresses: IpAddresses.cidr('10.0.0.0/16'),
      // An ALB requires subnets in at least two AZs, so this scenario cannot be
      // single-AZ the way the ec2 one is. Still no NAT gateway.
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        { name: 'Public', subnetType: SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });

    const cluster = new Cluster(this, 'Cluster', { vpc });

    const logGroup = new LogGroup(this, 'ServiceLogGroup', {
      retention: RetentionDays.ONE_DAY,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const taskDefinition = new FargateTaskDefinition(this, 'TaskDef', {
      cpu: 256,
      memoryLimitMiB: 512,
    });
    taskDefinition.addContainer('AppContainer', {
      image: ContainerImage.fromRegistry('public.ecr.aws/nginx/nginx:stable'),
      portMappings: [{ containerPort: 80 }],
      logging: LogDrivers.awsLogs({ logGroup, streamPrefix: 'cdkd-bench-ecs' }),
    });

    const albSg = new SecurityGroup(this, 'AlbSg', {
      vpc,
      description: 'cdkd-bench ecs alb',
      allowAllOutbound: true,
    });
    albSg.addIngressRule(Peer.anyIpv4(), Port.tcp(80), 'HTTP from anywhere');

    const serviceSg = new SecurityGroup(this, 'ServiceSg', {
      vpc,
      description: 'cdkd-bench ecs service',
      allowAllOutbound: true,
    });
    serviceSg.addIngressRule(albSg, Port.tcp(80), 'HTTP from the ALB');

    const alb = new ApplicationLoadBalancer(this, 'Alb', {
      vpc,
      internetFacing: true,
      securityGroup: albSg,
      vpcSubnets: { subnetType: SubnetType.PUBLIC },
    });

    const targetGroup = new ApplicationTargetGroup(this, 'TargetGroup', {
      vpc,
      port: 80,
      protocol: ApplicationProtocol.HTTP,
      targetType: TargetType.IP,
      healthCheck: { path: '/', healthyThresholdCount: 2, interval: cdk.Duration.seconds(10), timeout: cdk.Duration.seconds(5) },
    });

    alb.addListener('Listener', {
      port: 80,
      protocol: ApplicationProtocol.HTTP,
      defaultTargetGroups: [targetGroup],
    });

    const service = new FargateService(this, 'Service', {
      cluster,
      taskDefinition,
      desiredCount: 1,
      // Public subnet + public IP so the task can pull the registry image
      // without a NAT gateway.
      assignPublicIp: true,
      vpcSubnets: { subnetType: SubnetType.PUBLIC },
      securityGroups: [serviceSg],
    });
    service.attachToApplicationTargetGroup(targetGroup);

    new cdk.CfnOutput(this, 'AlbDnsName', { value: alb.loadBalancerDnsName });
    new cdk.CfnOutput(this, 'ClusterName', { value: cluster.clusterName });
    new cdk.CfnOutput(this, 'ServiceName', { value: service.serviceName });
  }
}
