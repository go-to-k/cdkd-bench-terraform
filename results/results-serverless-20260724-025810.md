# Benchmark: serverless stack

- Date: 2026-07-24 02:58:10  Region: us-east-1  RUNS: 3 (median)
- cdkd: 0.260.10  cdk: 2.1132.1 (build 237e1b2)  terraform: Terraform v1.15.8

Metric = median cold end-to-end deploy wall-time (setup untimed).

| Tool | Deploy (median) | all runs |
|---|---|---|
| cdkd | 32.1s | 30.9s 32.1s 33.9s  |
| cdkd --no-wait | 32.0s | 33.9s 29.7s 32.0s  |
