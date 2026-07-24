# Benchmark: cloudfront stack

- Date: 2026-07-24 03:27:49  Region: us-east-1  RUNS: 3 (median)
- cdkd: 0.260.10  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| cdkd | 173.9s | 170.3s 182.6s 173.9s  |
| cdkd --no-wait | 17.8s | 15.0s 17.8s 18.2s  |
