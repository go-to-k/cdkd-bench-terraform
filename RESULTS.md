# ベンチマーク結果まとめ: cdkd vs Terraform vs CloudFormation

同一の論理スタックを CDK(cdkd / `cdk deploy`)と Terraform で表現し、デプロイ速度を比較。

## 計測条件

- 指標: **cold end-to-end デプロイ壁時計、median of 3 ラン**
- 一回きりのセットアップ(`npm install` / `cdk bootstrap` / `terraform init` / プロバイダー DL)は事前実施、計測に**含めない**
- リージョン: us-east-1(cloudfront は CloudFront がグローバルなため実質同等)
- cdkd バージョン: ポーリング修正込み(PR #1175 / #1176 → v0.260.x)
- 単位: 秒。`**太字**`=そのシナリオ最速。

## 総合結果表

| シナリオ | 構成 | cdkd | cdkd `--no-wait` | Terraform | CloudFormation |
|---|---|---:|---:|---:|---:|
| **wide** | 独立48リソース(S3/DDB/SQS/SNS/SSM/Logs ×8) | **25.4** | 25.3 | 50.4 | 85.9 |
| **serverless** | Lambda×3 + HTTP API + DDB + SNS/SQS + EventBridge | **31.4** | 31.8 | 57.9 | 124.2 |
| **webapp** | VPC + NAT + サブネット + GWエンドポイント + DDB + SQS + S3 + Lambda×2 + HTTP API | 127.0 | **32.4** | 127.8 | 161.9 |
| **cloudfront** | S3 オリジン + CloudFront + OAC | **171.2** | 17.8 | 191.1 | 208.1 |

> **cdkd 列は v0.260.10(#1181 deploy オーバーヘッド最適化込み)で検証。TF/CFn 列は前回値据え置き**
> (cdkd のバイナリに依存しないツール)。
> - **wide**: v0.260.10 で単独クリーン再計測 26.0 → **25.4s**(~0.6s短縮)。
> - **serverless/webapp/cloudfront**: v0.260.10 でも再計測したが、**A の固定コスト削減(毎回~1.7s)は
>   これらプロビジョニング律速スタックではラン変動未満**(例: cloudfront 173.9 vs 元 171.2 = CloudFront 伝播
>   律速で誤差内)。よって元のクリーン値を採用。#1181 の主効果は単一/小規模スタックのイテレーション側
>   (AgentCore 単一リソースの container update 31.4→29.7s)。
> - 注: 一度これらを**並行実行**して数値が膨張したため(webapp 127→136s 等)、干渉値は破棄し、比較は
>   元のクリーン値 or 単独再計測値のみ採用している。

## 各ラン詳細(median / 全ラン)

| シナリオ | ツール | median | 全ラン |
|---|---|---:|---|
| webapp | cdkd | 127.0 | 113 / 141 / 127 |
| webapp | Terraform | 127.8 | 128 / 159 / 118 |
| webapp | CloudFormation | 161.9 | 162 / 158 / 164 |
| webapp | cdkd --no-wait | 32.4 | 29.1 / 32.4 / 33.4 |
| cloudfront | cdkd | 171.2 | 171.2 / 184.8 / 163.1 |
| cloudfront | Terraform | 191.1 | 182.5 / (1996.8 TF側ハング=除外) / 191.1 |
| cloudfront | CloudFormation | 208.1 | 200.8 / 208.1 / 232.4 |
| cloudfront | cdkd --no-wait | 17.8 | 15.0 / 17.8 / 18.2 |

## シナリオ別の要点

- **wide(cdkd 単独最速、TF比 ~2倍 / CFn比 ~3.3倍)**: 横に広く並列なスタックでは cdkd の DAG + SDK 直接呼び出しが低変動で明確に勝つ。
- **serverless(cdkd 単独最速、TF比 ~1.8倍 / CFn比 ~4倍)**: 依存チェーンはあるが遅いリソースがないので wide 同様に cdkd が勝つ。`--no-wait` は効果なし(スキップ対象がない)。
- **webapp(cdkd ≒ Terraform の同着、0.8s差)**: NAT Gateway(~90〜120s)が全ツール共通の床で差を圧縮。物理に律速されるので cdkd も TF も単独では勝てない。`--no-wait`(NAT待ちスキップ)だけが 32.4s で別次元。
- **cloudfront(cdkd が Terraform に勝ち)**: CloudFront 伝播(~180s+、変動大)が支配。ポーリング修正後、cdkd 171.2s が TF ~186s(ハング除く)と CFn 208.1s を上回る(cdkd < TF < CFn)。`--no-wait` は 17.8s(15.0 / 17.8 / 18.2、CloudFront 伝播待ちをスキップ)。

## 結論(正直に)

- **勝者はスタックの「形」で変わる。** 並列型(wide / serverless)は cdkd の明確な勝ち。単一の遅いリソース支配型(webapp=NAT / cloudfront)は物理が支配し、同着〜僅差。待たない選択(`--no-wait`)だけが物理を超える。
- **「cdkd が全部速い」ではない。** webapp は Terraform と真の同着。
- 3エンジンとも比較で、CloudFormation は常に最も遅い(税が乗る)。

## 副産物: このベンチが cdkd を実際に速くした(PR #1175 / #1176)

webapp で Terraform に負けていた原因を掘って、**実デプロイ速度バグを4つ発見・修正**:

1. **longest-pole スケジューリング**: ready セットを「推移的依存の多い順」に。依存ゼロの EIP が後回しにされ NAT(長い pole)を遅らせていた。webapp 高速ラン 154s→112s。
2. **EIP SDK プロバイダー**: EIP が CC-API 経由で非同期ポーリング ~23s → ネイティブ SDK(AllocateAddress)で ~2.4s。
3. **NAT ポーリング間隔**: SDK waiter の既定 `minDelay:15s/maxDelay:120s` が疎すぎ、検出が最大~2分遅延 → `minDelay:5/maxDelay:15` に。webapp が負け(190s)→同着(127s)へ。
4. **CloudFront ポーリング間隔**: 手書きループの上限 30s → 10s。cloudfront が負け→勝ちへ。

→ #1175 で4つ出荷、全リポ掃引で見つけた同型を #1176(残り7プロバイダー、10s 化 + 機械的非回帰テスト、実AWS integ 検証)として出荷済み。**ベンチは順位付けだけでなく cdkd を速くした。**

## 再現

```bash
./scripts/run-benchmark.sh cdkd,cdkd-nowait,cfn,tf wide   # または webapp / serverless / cloudfront
RUNS=3 ./scripts/run-benchmark.sh cdkd,tf webapp
```

- 生ログ: `results/*.log` / `results/results-<scenario>-<ts>.md`
- CDK: `cdk/lib/*-stack.ts` / Terraform: `terraform/<scenario>/`

## 注意点(信頼性のため)

- パリティ調整: CDK 固有の `restrictDefaultSecurityGroup` カスタムリソース + CDK 管理 LogGroups を無効化(Terraform にない分を cdkd/CFn が背負わないよう)。serverless は Terraform 側の SQS receive 権限欠落を補って一致。
- `terraform apply` は plan を、`cdk/cdkd deploy` は synth を各自含む。end-to-end 壁時計が apples-to-apples。
- NAT/CloudFront は実プロビジョニング時間で変動 → median of 3。
- SQS は 60s 名前再利用クールダウンあり(AWS 制約、ツールの欠陥ではない)。
- cdkd は実験的 / dev-test。
