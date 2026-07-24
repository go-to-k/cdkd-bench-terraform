# ブログ土台(引き継ぎ仕様): cdkd vs Terraform デプロイ速度ベンチマーク

> これは実際にブログ本文を書くエージェント(別リポ)向けの引き継ぎ仕様。ナラティブ、データ、
> 発見、注意点、数値の入手先を含む。プレースホルダ数値を最終値扱いしないこと。実値はこのリポの
> `results/results-<scenario>-<ts>.md` から拾う。

## メタ

- **タイトル案**
  - 「cdkd vs Terraform vs CloudFormation: CloudFormation を使わない CDK デプロイは実際どれだけ速いか」
  - 「同じスタックで3つの IaC エンジンを競争させる: cdkd, Terraform, CloudFormation」
- **読者**: CDK と Terraform を知る AWS/IaC エンジニア。dev/test ループのデプロイ・イテレーション速度を気にする人。
- **一行テーゼ**: cdkd(CDK を AWS SDK / Cloud Control で直接デプロイ、CloudFormation なし)は CloudFormation より明確に速く、Terraform とは互角〜やや上。差はスタックの形で決まる。
- **正直なフレーミング**: cdkd は実験的 / dev-test 専用。「本番パイプラインを置き換えよう」ではなく「CloudFormation 税は実際どれだけあるか、直接API はどこで勝つか」の話。

## なぜこの比較が面白いか

- **CloudFormation** は control plane: change set + スタックイベントのポーリング + ロールバック管理。生の AWS API 呼び出しに固定オーバーヘッドを乗せる。
- **cdkd** は同じ CDK アプリ/合成テンプレートを、直接プロビジョニング(SDK プロバイダー、Cloud Control API フォールバック)+ イベント駆動 DAG(レベルバリアなし)で処理する。
- **Terraform** も自身のグラフから AWS API を直接叩く。
- なので本当の勝負は **cdkd vs Terraform**(どちらも直接API)。CloudFormation は「自分がどれだけ税を払っているか」のベースライン。結果は自明ではなく、スタックの形で変わる。

## 何を計ったか

- 同じ論理スタックを2通りで表現、リソース対リソースで極力等価に:
  - CDK アプリ(`cdk/`。cdkd と `cdk deploy` の両方でデプロイ)
  - Terraform HCL(`terraform/<scenario>/`)
- 指標 = **単一の cold end-to-end デプロイ壁時計(median of 3)**。一回きりのセットアップ(`npm install`, `cdk bootstrap`, `terraform init`, プロバイダー DL)は事前に済ませ計測に含めない(日常利用を模す)。
- リージョン us-east-1。ツールバージョンは各 `results/*.md` のヘッダに記録。

### シナリオ(記事の背骨 — 各1セクション)

1. **wide** — 48個の完全独立リソース(S3 / DynamoDB / SQS / SNS / SSM / CloudWatch Logs を各8)。依存チェーンなし、遅いリソースなし。純粋なオーケストレーション throughput(DAG 並列性 + 呼び出しごとオーバーヘッド)を切り出す。
2. **webapp** — 「典型的な」VPC Web アプリ: VPC + NAT Gateway×1 + サブネット + S3/DynamoDB ゲートウェイエンドポイント + DynamoDB + SQS + S3 + Lambda×2 + HTTP API。NAT Gateway(AWS 側で約1.5〜2分の作成)が支配。
3. **serverless** — Lambda×3 + HTTP API + DynamoDB + SNS/SQS + EventBridge、VPC なし。実際の依存チェーンはあるが遅いものはない、中間ケース。
4. **cloudfront** — S3 オリジン + CloudFront ディストリビューション + OAC。全ツールが待つ単一の遅いグローバルリソース(約3〜6分)。

> 4シナリオが要点: 勝者は形で変わる。「純並列 throughput」(wide)から「単一の遅いリソース支配」(cloudfront)までのスペクトルとして提示する。

## データ(`results/` から埋める — 現時点の既知値)

### wide(median of 3、FINAL)

| ツール | Deploy(median) |
|---|---|
| **cdkd** | **25.4s**(最速) |
| Terraform | 50.4s |
| CloudFormation | 85.9s |

- cdkd は Terraform の約2倍、CloudFormation の約3.4倍速い。
- 要点: スタックが横に広く並列なら、cdkd の DAG + SDK 直接呼び出しが低変動で明確に勝つ。
- (v0.260.10 で 26.0→25.4s に再計測。#1181「bucket解決∥synth」で毎回 ~1.7s の固定コストを削るが、wide は
  プロビジョニング律速なので効果 ~0.6s。固定コスト最適化の主効果は単一/小規模スタックのイテレーション側。)

### webapp(median of 3、FINAL — cdkd 3修正後)

| ツール | Deploy(median) | 全ラン |
|---|---|---|
| **cdkd --no-wait** | **32.4s** | 29.1 / 32.4 / 33.4(超安定) |
| cdkd | 127.0s | 113 / 141 / 127 |
| Terraform | 127.8s | 128 / 159 / 118 |
| CloudFormation | 161.9s | 162 / 158 / 164(別セッション) |

before/after のストーリー: NAT ポーリングバグがあった頃 cdkd は 190.9s(median)で Terraform の
127s に負けていた。修正後は cdkd 127.0s = Terraform 127.8s と完全同着(0.8s 差、NAT 変動内)。
修正が cdkd を「負け」から「同着」へ引き上げた。

- ストーリー: NAT Gateway(約1.5〜2分)は全ツール共通の床で、差を圧縮する。cdkd と Terraform は
  統計的にタイ(どちらも NAT 作成時間で揺れる)、両者とも CloudFormation(161.9s)に勝つ。
- `cdkd --no-wait` は別次元(約32s、極めて安定)。NAT の "available" 待ちをスキップする fire-and-forget トレードオフだから。
- 教訓: 単一の遅い直列 AWS リソースに律速されるスタックでは、どのエンジンも物理には勝てない。ツールの
  オーバーヘッドは共通の待ち時間に乗る薄い層で、「勝つ」唯一の方法は待つのをやめる(--no-wait)こと。
- v1(スケジューラ修正 + パリティ修正の前)との対比: cdkd は 167s で Terraform 128s に負けていた。
  longest-pole スケジューリング修正 + CDK 固有カスタムリソース除去で同着まで詰めた。良い before/after。

### serverless(median of 3、FINAL)

| ツール | Deploy(median) |
|---|---|
| **cdkd** | **31.4s**(最速) |
| Terraform | 57.9s |
| CloudFormation | 124.2s |

- cdkd は Terraform の約1.8倍、CloudFormation の約4倍速い。
- serverless は実際の依存チェーン(Lambda → integration → route。rule → target → permission)はあるが
  遅いものはないので、cdkd の速い SDK 経路 + longest-pole スケジューリングが wide 同様に明確に勝つ。
- `cdkd --no-wait` = 31.8s(効果なし。スキップするものがない)。
- (作成中に見つけたパリティ注記: Terraform 設定が最初、consumer Lambda ロールの SQS receive 権限を
  欠いていた。CDK の SqsEventSource は自動付与する。リソースセットが一致するよう修正済み。)

### cloudfront(RUNS=3 median、ポーリング修正後)

| ツール | Deploy(median) | 全ラン |
|---|---|---|
| **cdkd --no-wait** | **17.8s** | CloudFront "Deployed" 待ちをスキップ |
| **cdkd** | **171.2s** | 171.2 / 184.8 / 163.1 |
| Terraform | 191.1s | 182.5 / 1996.8(TF 側ハング、無視) / 191.1 |
| CloudFormation | 208.1s | 200.8 / 208.1 / 232.4 |

- どんでん返し: 最初の cloudfront ランでは cdkd が負けていた(cdkd 183s vs TF 178s、各ランで cdkd 約182〜215s
  vs TF 約156〜179s と一貫して遅い)。verbose ログを掘ると **3つ目のスパースポーリングバグ** を発見 —
  `CloudFrontDistributionProvider` の手書き待機ループが指数バックオフを 30s で上限打ちしていて、
  ディストリビューションが遅いポーリング直後に `Deployed` に達すると検出が最大約30s 遅れていた。NAT waiter と
  同じクラス、別プロバイダー。10s 上限に修正。
- 修正後: cdkd 171.2s が Terraform(ハングでないランで約186s)を上回る。CloudFront 律速スタックで
  cdkd を負けから勝ちに反転させた。
- `cdkd --no-wait` 17.8s(15.0 / 17.8 / 18.2、伝播待ちをスキップ、fire-and-forget)。
- 記事にとって良い「3つ目の最適化」ビート: ベンチが1つでなく **3つのスパースポーリングレイテンシバグ**
  (NAT waiter、EIP-on-CC、CloudFront ポーリング)を炙り出し、全て同じ cdkd PR(#1175)で出荷。
  全リポ掃引で同型パターンをさらに約6プロバイダーで発見し、フォローアップ(#1176)として出荷。

> 書き手へ: headline 表を「シナリオ × ツール(median)」で作り、各シナリオ1サブセクションで
> なぜその順位になったかを説明する。

## データ中の最良ストーリー: ベンチから本物の cdkd 改善が出た

webapp をベンチ中、cdkd が想定より遅かった。根本原因(verbose デプロイログ):

- cdkd の DAG executor が "ready" リソースを **テンプレート logical-id 順** で選んでいた(並列度10で律速)。
- 依存ゼロの `AWS::EC2::EIP` が logical-id で後ろにソートされ、43個中約28番目に開始 — その依存先の
  **NAT Gateway**(約2分の長い pole)をデプロイ末尾に押しやっていた。CloudFormation は EIP を
  最初の波で開始し、NAT 待ちを他全部と重ねていた。

**修正**(cdkd PR として出荷): ready セットを **longest-pole 優先** で並べる — より多くの推移的依存を
ブロックするリソースを葉より先に開始。修正後 EIP は t=0 で開始(verbose ログで確認)、webapp デプロイは
高速ランで約154s → 約112s に低下。

- 「ベンチが本物の最適化を見つけた」良いビート。before/after と一行直感(長い pole を先に始めろ)を入れる。

**2つ目の最適化(これもベンチから出荷): EIP SDK プロバイダー。**
スケジューラ修正後も cdkd は webapp で Terraform と同着どまり。掘ると: EIP に SDK プロバイダーがなく
Cloud Control API 経由で、その非同期ポーリングバックオフ(1s → 1.5 → 2.25 → … → 10s)が、AWS が
即時割り当てるリソースに約23s かかっていた。Terraform は EIP を直接 SDK 呼び出し(即時)で作る。EIP は
クリティカルパスの NAT に接続するので、この約23s は純粋なハンデ。修正: `AWS::EC2::EIP` にネイティブ EC2
SDK プロバイダー(AllocateAddress / ReleaseAddress)を追加。修正後 EIP は約23s → 約2.4s で作成(ログで確認)。

**3つ目の最適化(最大): NAT Gateway 待ちのポーリング間隔。**
スケジューラ + EIP 修正後も cdkd は webapp で Terraform に負け続け(cdkd 約190s vs TF 約127s)、しかも
全ランで一貫 — 変動でなく系統的ギャップ。根本原因(AWS SDK ソースを読んで判明): cdkd は NAT gateway を
SDK の `waitUntilNatGatewayAvailable` で待っていて、その **既定ポーリングは指数バックオフ
`minDelay: 15s, maxDelay: 120s`**。NAT は約90s で `available` になるが遅いポーリングは最大120s 間隔なので、
cdkd は準備完了を実際より最大約2分遅れて検出 — 準備の瞬間がスパースなスケジュールのどこに落ちるかで
合計が大きく揺れた(同一スタックで 124s〜219s)。Terraform は短間隔ポーリングなので即座に検出。
修正: waiter を `minDelay: 5, maxDelay: 15` に上書きし検出遅延を約15s に抑える。

- 修正後 cdkd は実際の NAT 作成時間(約90〜120s)+ 数秒を追随、Terraform と同じ。webapp は真の同着に
  (両者とも約100s の不可避 NAT プロビジョニング待ちに律速)。
- 「ベンチが本物のバグを見つけた」最強ビート: cdkd は NAT を含む任意スタックで静かに実際遅く、
  短間隔ポーリングのピア(Terraform)との直接対決だけがそれを可視化した。

**記事向けまとめナラティブ**: 3つの独立した cdkd 修正(longest-pole スケジューリング、EIP SDK
プロバイダー、NAT ポーリング間隔)が、全て webapp で Terraform と競争しただけから出た。ベンチはツールを
順位付けしただけでなく、cdkd を速くした。ここを payoff として強調する。

- webapp の正直な結論: これは NAT Gateway 支配。NAT 作成時間(約90〜120s、変動)は cdkd と Terraform が
  同一に払う床で、どちらも単独では勝てない。修正は cdkd を「負け」から真の同着へ動かした。NAT 律速スタックを
  「勝つ」唯一の方法は `cdkd --no-wait`(待ちをスキップ、32.4s)= fire-and-forget。cdkd の明確な勝ちは
  非 NAT シナリオ(wide, serverless)。

## 公平性 / 注意点(記事に必須 — 信頼性)

- パリティのため除いた CDK 固有の追加: `restrictDefaultSecurityGroup` カスタムリソース(Lambda バック)と
  CDK 管理 LogGroups を無効化し、cdkd/CFn が Terraform 設定にないリソースを背負わないようにした。
- 一回きりのセットアップ(init/bootstrap/install)は除外 — 全ツール同条件。
- `terraform apply` は自身の plan を含み、`cdk/cdkd deploy` は自身の synth を含む。end-to-end デプロイ
  壁時計が apples-to-apples の数値。
- 結果は AWS API レイテンシと、NAT/CloudFront では実プロビジョニング時間で変わる — なので median of 3、
  なので正直な「形による」フレーミング。
- 引っかからない方が良いベンチアーティファクト(脚注価値あり): SQS は 60s の名前再利用クールダウンがあり、
  削除後60s 以内に同名キューを再作成するとリトライが起きる。runner は考慮済み。AWS の制約でツールの欠陥ではない。
- cdkd は実験的。はっきり書く。

## `cdkd --no-wait`

cdkd には遅いタイプ(RDS, CloudFront, ElastiCache, EC2, …)の安定化待ちをスキップする `--no-wait` フラグが
ある。効果は遅安定リソースのあるシナリオ(webapp NAT / cloudfront)で出る。wide/serverless では
スキップするものがないので出ない。`--no-wait` 列は数値が動く場所でだけ取り上げる。

## 推奨記事構成

1. フック: 「CloudFormation は実際どれだけデプロイ時間を食っているのか?」
2. セットアップ: 同じスタック、3エンジン、何を計り何を計らないか。
3. シナリオのスペクトル(wide → serverless → webapp → cloudfront)、各1順位表 + 短い「なぜ」。
4. どんでん返し: ベンチが本物の cdkd スケジューリング最適化(EIP/NAT longest-pole)を炙り出した — before/after。
5. 公平性セクション(上記の注意点)。
6. 結論: 直接API が勝つ場所(wide/並列)、物理が支配する場所(単一の遅いリソース)、Terraform と cdkd が
   互角の場所。
7. 再現: このリポ、`./scripts/run-benchmark.sh <tools> <scenario>`。

## 再現(記事付録用)

- リポ: `cdkd-bench-terraform`(このリポ)。
- `./scripts/run-benchmark.sh cdkd,cdkd-nowait,cfn,tf wide`(または `webapp` / `serverless` / `cloudfront`)、`RUNS=3`。
- CDK スタック: `cdk/lib/*-stack.ts`。Terraform 等価物: `terraform/<scenario>/`。
- 使用した改善版 cdkd: 3つのポーリング修正は cdkd v0.260.x に出荷済み(PR #1175 / #1176)。

## 書き手へのトーン指針

- 中立で正直に。cdkd は筆者のプロジェクトなので誇張を避ける。
- 「形による」ニュアンスを要点にする。「cdkd が全部勝つ」ではない。
- 数値は実 AWS の median。変動が効く場所(NAT)は明記する。
- 最終原稿では em-dash(—)を使わない(プロジェクトの表記方針)。
