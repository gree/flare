# Claude Code 引き継ぎ — flare operator / RocksDB WAL

記録日: 2026-09-30 JST。以下は記録時点の状態。再開時に Git / GitHub を再確認すること。

## 目的と進め方

ユーザーの目的は、通常の瞬断で replica の欠損を修復でき、遅延を小さく保ち、
遅れた slave が古い値をローカルから返さず master へ proxy すること。
operator / RocksDB を本番導入できる状態にするため、開発・検証を継続している。

- 重い検証は **CI 優先**。ローカルで長時間の kind / Nix / polling を並べない。
- STAMP/STPA の安全制約、コード、試験、実行 SHA、報告書を対応づける。
- 作者の試験成功と reviewer の評価は別。全 EV を一括 `verified` にしない。
- 実装完了、試験追加、実行成功、本番承認を区別する。
- この引き継ぎは新たな本番変更・PR マージの承認ではない。

## 現在地

- Repo: `/Users/junji.hashimoto/git/flare`
- Branch: `safety/saf-10-wal-replication`
- HEAD / remote HEAD: `7e979b0cba45dc103bcad083c2a688941cd77b8a`（push 済み）
- PR: https://github.com/gree/flare/pull/144 — OPEN / Draft、base `flare-operator`
- #143 はユーザーがマージ済み。#144 の base 変更も済み。
- この引き継ぎ作成前の追跡ファイルの未コミット差分は既存 `.gitignore` のみ。
  本資料はその後追加した未コミットファイル。

### 触らないもの

`.gitignore` の `_tmp*.md` 追加は既存のユーザー変更。未追跡の以下も既存物であり、
今回の成果物ではない。`git add .`、clean/reset、退避ファイルの上書きをしない。

`CLAUDE.md`, `CLAUDE.md~`, `Dockerfile`, `Gree Flare (K8s) Overview-1787045115108.json`
と `.bak`, `compile`, `debian-packages/`, `docker-compose.yml`, `flare.txt`,
`metadata.json`, `result`, `不明/`。

特に既存 `CLAUDE.md` をこの引き継ぎで置換しない。別 worktree
`/private/tmp/wt-saf01` も過去の作業用であり、勝手に削除しない。
このセッション末にローカルで長時間試験を起動したままにはしていない。
他セッションのプロセスは所有者・用途を確認せず停止しない。

## 最初に確認する CI

すべて head `7e979b0`。状態は本資料作成時点。

| Workflow | 状態 | URL |
|---|---|---|
| Safety evidence | PASS | https://github.com/gree/flare/actions/runs/36707837351 |
| nix-linux（legacy / RocksDB） | PASS | https://github.com/gree/flare/actions/runs/36707836926 |
| 通常 E2E（5 leg） | 実行中 | https://github.com/gree/flare/actions/runs/36707836842 |
| 手動 E2E `evaluation=sustained` | 実行中 | https://github.com/gree/flare/actions/runs/36707861123 |

手動評価は MORE 待機修正後の 300/900/2000 writes/s の再測定。
結果を見る前に同じ試験を重複起動しない。通常 PR CI は同一ブランチへの push で
前の実行をキャンセルし得るので、まず結果・失敗ログ・artifact を回収する。
PR checkout は merge revision の場合がある。head SHA と実際の tested SHA を混同せず、
artifact の `tested-sha.txt` と run 情報を確認する。artifact は30日保存。

前の `4a516e6` は全 workflow PASS:
E2E `36290501385`、nix-linux `36290501295`、evidence `36290501403`。
さらに前の `87f1728` も全 PASS。
これらは後続コミットや opt-in 評価の成功証跡ではない。

## 最近の実装（すでに入っている。再実装しない）

| Commit | 内容と限界 |
|---|---|
| `3cb1d5a` | 退避されていた audit follow-ups を #144 へ統合。WAL MORE の全件 skip 時も即再取得、flared local read guard、未観測ノードの read 抑止。 |
| `0ed3193`, `41db502` | 古い正の balance 下の GET を隔離する E2E。初回は読み取り本体成功・cleanup 失敗、次は地図が更新されて前提失敗。失敗を成功扱いしない。 |
| `92a46c4` | CRD / Helm に `blockCacheSizeMb`, `writeBufferSizeMb`, `maxWriteBufferNumber`。初回 ConfigMap にも種付け、migration 引き継ぎ。既存 Pod の自動再起動なし。地図隔離試験を operator↔replica の両方向へ強化。 |
| `87f1728` | TCP send エラーを捨てない。node sync の `OK` を期限付き確認。未確認配送を保持して lease fence 経由で再送。Pod 一覧取得失敗も成功にしない。共有 broadcast 待ち期限。 |
| `4a516e6` | 1 reconcile に1ノードの適用版監査。stats を Pod UID の前後読みで挟む。behind は再送、unknown / ahead は破壊的操作の根拠にしない。operator 起動時に現在の地図の再配送を要求。 |
| `7e979b0` | 監査の behind / ahead / unknown gauges、3アラート、runbook、本番投入判定表。60秒を超える観測、未来時刻、無効な観測は Unknown。現在の desired version で再比較。 |

### コードの入口

- `flare_operator/FlareOperator/Main.lean`: `reconcileOnceFSM` の post-commit
  配送、`pendingBroadcastRef`、`topologyAuditRef`、起動時初期化。
- `Server/TcpClient.lean`: `sendString`, `receiveTopologyAck`, `sendNodeSyncToNode`。
- `Server/TopologyBroadcast.lean`: `pendingTopologyAfterAttempt`, `broadcastTopologyToAllPods`。
- `StateMachine/TopologyObservation.lean`: 純粋な stats parser / judge / record /
  observedVerdict / summarize。判定はこの層に置く。
- `K8s/Bridge.lean`: `topologyProbe`。UID 2秒 / stats 3秒 / UID 2秒、各 kill grace 1秒。
  汎用 kubectl の30秒制限を3回使わない。コマンドは read-only、名前は argv。
- `StateMachine/FollowEvidence.lean`: read / promotion / deletion の適格性。
- `src/lib/cluster.cc::pre_proxy_read`, `src/lib/stats.h::follow_allows_local_read`:
  WAL slave のローカル read guard。Slave ロールは保持し master へ転送する。
- `src/lib/handler_wal_follower.h::retry_immediately`: MORE backlog の待機改善。
- `E2E/Tests/ContinuousReplication.lean`: 隔離 read、瞬断、再起動等。
- `K8s/FlareCluster.lean`, `Kubectl.lean`, `Migration/Provision.lean`,
  `helm/flare-operator/templates/{crds,flare-cluster}.yaml`: メモリ設定。
- `Metrics/Prometheus.lean`, `helm/flare-operator/templates/prometheusrule.yaml`:
  新規観測メトリクスとアラート。

`FlareOperator/` 以下の略記は `flare_operator/FlareOperator/` を基準にする。

## 守る保証と未保証

1. 転送と WAL は併用。同じ変更の識別・世代・順序・削除履歴に基づく共通適用規則。
   WAL を version 比較なしに生バッチで適用する旧経路へ戻さない。
2. データと適用 cursor は同じ WriteBatch。転送は contiguous cursor を進めない。
3. 瞬断だけでは全再構築しない。履歴消失・source history 変更は明示的な rebuild。
4. read guard は最後に観測した source head への追従判定であり、線形化可能な read
   の保証ではない。master 到達不能時の GET が cache miss に見える互換性課題が残る。
5. 非同期複製なので、master のデータ喪失前に replica へ届かなかった成功応答済み
   書き込みは失われ得る。ユーザーがこのケースも欠損ゼロを要求するなら、別の
   ACK / durability / promotion / writer fencing 設計が必要。ローカル syncWrites
   やバックアップだけで解決したと言わない。
6. lease 検査と送信は非アトミック。受信側 fencing は新しい版を見た受信者を守る。
   複製の source epoch と operator topology の leadership generation は別概念。

## 次の作業順

### 1. 現在の CI を完了まで確認し、結果を証跡へ

失敗したら、機能不具合・試験の前提不成立・環境障害をログで切り分ける。
re-run の green だけで既知 finding を消さない。sustained の結果では cursor lag、
内容一致、read 適格性、負荷停止後の解消時間、メモリを別々に評価する。
転送だけで内容が一致していても WAL が追いついているとは限らない。

### 2. 本番前に必要な残実装・決定

- **SAF-09**: Lease 削除・世代後退・新 leader の回復方針。
  recipient の大きい版を無条件に信じて operator 版を上げるのは解決ではない。
  今の観測は process-local diagnostics。永続的な適用管理、世代回復の設計と試験は未完。
- **SAF-08**: 観測の型・鮮度・同一性と、昇格／削除判断の残監査。
- **SAF-11**: 複数 tick にまたがる多数ノード障害で breaker が発動しない問題。
  期待する定義を確定し、純粋層で変更・試験する。
- stale slave から master に到達できない場合のクライアント向けエラー仕様。

### 3. 試験・測定の残り（CI / staging 中心）

- startup republish **だけ**で復旧する決定的 E2E。
- stats 読み中の同名 Pod 置換、operator 再起動＋stats 不能、非 WAL read 復帰。
- 長時間切断で WAL rotation / flush / compaction が実際に起きる保持・資源上限評価。
- T17: lock hold / starvation と、負荷下の read / proxy / reconcile / lease 遅延。
- 実効メモリ設定と RSS、実 DB サイズでの起動／probe／復元／failover 再構築時間。
- 修復要求の真の同時競合、遅れた／Unknown successor の昇格・削除経路。

### 4. 本番投入の判断

`docs/PRODUCTION-READINESS.md` が集約表。RPO/RTO、PVC/tmpfs、予算、保持期間、
バックアップ復元、監視通知、段階投入、停止・rollback 条件を明示する。
#144 のマージ可否と本番 WAL 有効化を混同しない。

## 既知の落とし穴

- メモリ3項目は startup-only。SIGHUP だけでは実効予算が変わらない。
  ConfigMap 反映を待ち、計画的 restart/migration を行う。tmpfs Pod 削除はデータ削除。
- メモリ予算は RSS cap ではない。CF ごとの memtable、compaction、複製、allocator、
  tmpfs を含める。「512 + 64×3 = 必ず704MB」などを厳密な下限・上限としない。
- 最後の rocksdb tuning field を消しても、現行 operator は既存 extra.conf を
  必ずしも消さない。既定値への復帰には明示値を使う。
- `OK` は送信時の処理確認であり、その後の Pod 再起動まで保証しない。
- topology audit は一巡に N passes。60秒以内に回れない規模では Unknown が増える。
  Unknown を正常扱いして警告を消さず、観測頻度・予算を測定／再設計する。
- gauges は reconcile で更新。operator が停止すると値も凍る。
  `up` と reconcile 進捗も監視する。
- report の古い「未実行」「退避中」は履歴記録。新しい SHA の結果で追記し、
  古い失敗を消したり、新コードへ古い PASS を流用したりしない。

## 検証・CI 操作

最後のローカル結果: unit 174/174、Helm fixture 3/3、evidence fixture 21/21、
operator build、helm lint、差分検査 PASS。これは `7e979b0` の実装作業時の結果。

```sh
git status --short
git fetch origin
gh pr view 144 --repo gree/flare
gh run list --repo gree/flare --branch safety/saf-10-wal-replication

python3 scripts/check_safety_evidence.py
python3 scripts/check_safety_evidence.py --base origin/flare-operator
python3 -m unittest discover -s scripts/tests -p 'test_safety_evidence.py'
python3 -m unittest discover -s scripts/tests -p 'test_helm_memory.py'
helm lint helm/flare-operator
git diff --check
```

Lean は `flare_operator/` で `lake build flare_unit` → unit 実行、必要な対象だけ build。
library と executable root の同時 build は過去に Main リンク競合があったため、
CI 同様 `lake build FlareOperator`、`lake build flare_operator`、`lake build flare_e2e`
を別呼び出しにする。

既存 `.github/workflows/e2e-tests.yaml` の手動 `evaluation` は
`none` / `sustained` / `scale-2m` / `scale-15m8`。
選択した評価は continuous-replication leg で有効化され、他4 leg も実行される。
通常 PR 実行では opt-in 評価は SKIP。SKIP を性能合格と数えない。
手動例（既存実行が終わっていることを確認してから）:

```sh
gh workflow run e2e-tests.yaml --repo gree/flare \
  --ref safety/saf-10-wal-replication -f evaluation=sustained
```

## 証跡の更新方法

`docs/safety-evidence.json` の変更対象 EV に、実際の影響評価・コード参照・試験参照・
run を追加し、報告書を `docs/reports/` に保存する。実装 SHA と記録コミットを分ける。
`--write` は必要な生成表の同期であり、試験を走らせたり安全を証明したりしない。
新しい check を追加したら checker fixture の完全な PASS 記録も確認する。
直近では CHECK-01-observation 追加で、1 check を決め打ちした正例 fixture が壊れ、
全 check の同一 SHA 成功記録を生成するよう修正済み。検査器の条件は緩めていない。

まず読む資料: `docs/REVIEW-GUIDE.md`, `docs/SAFETY-TODO.md`,
`docs/PRODUCTION-READINESS.md`, `docs/design-continuous-wal-replication.md`,
`docs/STPA-node-state.md`, `docs/RUNBOOK.md`。最近の根拠は
`docs/reports/2026-09-2{6,7}-*` と `docs/reports/2026-09-30-topology-monitoring.md`。

この資料だけを追加するために CI 中のコードへ無用な push をしない。
ユーザーに引き継いだ後は、他エージェントと同じブランチを同時編集しないこと。
