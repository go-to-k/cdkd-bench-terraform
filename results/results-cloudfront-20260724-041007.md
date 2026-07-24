# Benchmark: cloudfront stack

- Date: 2026-07-24 04:10:07  Region: us-east-1  RUNS: 3 (median)
- cdkd: 0.260.10  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| CloudFormation | 208.1s | 200.8s 208.1s 232.4s  |
