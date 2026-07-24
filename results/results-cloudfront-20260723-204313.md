# Benchmark: cloudfront stack

- Date: 2026-07-23 20:43:13  Region: us-east-1  RUNS: 1 (median)
- cdkd: 0.260.7  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| cdkd | 181.5s | 181.5s  |
| cdkd --no-wait | 20.0s | 20.0s  |
| Terraform | 156.0s | 156.0s  |
