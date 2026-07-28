import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import {
  AmazonLinuxCpuType,
  BlockDeviceVolume,
  EbsDeviceVolumeType,
  Instance,
  InstanceClass,
  InstanceSize,
  InstanceType,
  IpAddresses,
  MachineImage,
  Peer,
  Port,
  SecurityGroup,
  SubnetType,
  Vpc,
} from 'aws-cdk-lib/aws-ec2';
import { Role, ServicePrincipal, ManagedPolicy } from 'aws-cdk-lib/aws-iam';

const INSTANCE_COUNT = 3;

/**
 * A "three plain servers" stack: VPC (1 AZ, public only) + SecurityGroup +
 * IAM Role + InstanceProfile + 3 x t3.micro with an explicit EBS root volume.
 *
 * Why this shape (see cdkd-bench-terraform#4):
 *   - No NAT gateway. The webapp scenario already measures that 90-120s floor,
 *     and it would dominate everything else in this row.
 *   - No ALB and no AutoScalingGroup. ASG completion differs across all three
 *     engines (Terraform waits for capacity by default, CloudFormation does not
 *     without a CreationPolicy), so no fair row exists for it. The ALB belongs
 *     to the ecs scenario.
 *   - Three instances rather than one, so the row carries a parallelism signal
 *     on top of the single-instance `running` floor.
 *
 * All three engines agree on the completion definition here: cdkd, Terraform
 * (`aws_instance`) and CloudFormation all wait for the instance to reach
 * `running`. Terraform offers no opt-out, so the fire-and-forget column is
 * cdkd-only and is reported as N/A for Terraform rather than left blank.
 *
 * Authored with the L2 `Instance` construct on purpose: this suite measures
 * what a normal CDK app gets, not a hand-tuned L1 template. Note that
 * `associatePublicIpAddress` is deliberately NOT set — setting it makes CDK
 * drop `SubnetId` / `SecurityGroupIds` and emit `NetworkInterfaces` instead,
 * which is still a cdkd silent drop (cdkd#1281) and would route the instances
 * through the Cloud Control API. Public subnets already map a public IP on
 * launch, so the property is unnecessary here.
 *
 * Kept equivalent to terraform/ec2/main.tf.
 */
export class Ec2Stack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const vpc = new Vpc(this, 'Vpc', {
      ipAddresses: IpAddresses.cidr('10.0.0.0/16'),
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [
        { name: 'Public', subnetType: SubnetType.PUBLIC, cidrMask: 24 },
      ],
    });

    const securityGroup = new SecurityGroup(this, 'InstanceSg', {
      vpc,
      description: 'cdkd-bench ec2 scenario',
      allowAllOutbound: true,
    });
    securityGroup.addIngressRule(
      Peer.ipv4(vpc.vpcCidrBlock),
      Port.tcp(80),
      'HTTP from inside the VPC',
    );

    // The L2 Instance creates the InstanceProfile for this role automatically,
    // which is the InstanceProfile half of the resource graph.
    const role = new Role(this, 'InstanceRole', {
      assumedBy: new ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    const machineImage = MachineImage.latestAmazonLinux2023({
      cpuType: AmazonLinuxCpuType.X86_64,
    });

    for (let i = 0; i < INSTANCE_COUNT; i++) {
      const instance = new Instance(this, `Instance${i}`, {
        vpc,
        role,
        securityGroup,
        instanceType: InstanceType.of(InstanceClass.T3, InstanceSize.MICRO),
        machineImage,
        vpcSubnets: { subnetType: SubnetType.PUBLIC },
        blockDevices: [
          {
            deviceName: '/dev/xvda',
            volume: BlockDeviceVolume.ebs(8, {
              volumeType: EbsDeviceVolumeType.GP3,
              encrypted: true,
              deleteOnTermination: true,
            }),
          },
        ],
      });
      // Inline UserData keeps the scenario assetless — no S3 upload on either
      // side, so the asset-skip asymmetry noted in #3 does not apply.
      instance.addUserData('echo cdkd-bench ec2 >/var/log/cdkd-bench.log');

      new cdk.CfnOutput(this, `Instance${i}Id`, { value: instance.instanceId });
    }

    new cdk.CfnOutput(this, 'VpcId', { value: vpc.vpcId });
  }
}
