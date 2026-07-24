# Benchmark: cloudfront stack

- Date: 2026-07-23 22:20:24  Region: us-east-1  RUNS: 3 (median)
- cdkd: 0.260.7  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| cdkd | 183.1s | 182.8s 215.5s 183.1s  |
| Terraform | 177.9s | 179.0s 177.9s 156.1s  |
