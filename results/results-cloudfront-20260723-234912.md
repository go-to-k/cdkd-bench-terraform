# Benchmark: cloudfront stack

- Date: 2026-07-23 23:49:12  Region: us-east-1  RUNS: 3 (median)
- cdkd: 0.260.7  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| cdkd | 171.2s | 171.2s 184.8s 163.1s  |
| Terraform | 191.1s | 182.5s 1996.8s 191.1s  |
