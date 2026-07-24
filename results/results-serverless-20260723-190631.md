# Benchmark: serverless stack

- Date: 2026-07-23 19:06:31  Region: us-east-1  RUNS: 3 (median)
- cdkd: 0.260.7  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| cdkd | 31.4s | 32.0s 31.4s 29.9s  |
| cdkd --no-wait | 31.8s | 31.4s 32.0s 31.8s  |
| CloudFormation | 124.2s | 128.0s 124.2s 123.9s  |
| Terraform |  |  57.9s 57.9s  |
