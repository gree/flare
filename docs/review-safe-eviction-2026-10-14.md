# 安全な自動退避（safe-to-evict 解除）— 調査結果と実装方針（レビュー依頼）

2026-10-14。調査対象は `d9d9961`（コードは candidate `16921a5` と同一）。
**本書はレビュー依頼であって承認ではない。** annotation 変更・eviction・drain・Pod 削除・
クラスタ変更は一切行っていない。pf-dev 準備の既承認範囲（moc2-k8s #9600 を含む）は変えない。

問い: 「safe-to-evict:false を将来外し、Cluster Autoscaler（CA）による安全な自動退避を
可能にする保証はいつできるか。実装してからテストするのでは？」

**結論: 保証は現時点で存在しない。** 今の flare は、退避要求を受理する前（Pod に
`deletionTimestamp` が付く前）に、データ安全性を判定して拒否・延期する仕組みを一つも
持っていない。持っているのは、削除が始まった後の有限の猶予（pf-dev では preStop 60 s、
terminationGracePeriodSeconds 90 s）の中で master の引き継ぎを試みる制御だけである。
これは「安全になるまで削除を止める」制御ではない。引き継ぎできなければ、猶予切れで
Pod は消える（tmpfs ならデータも消える）。

順序は「実装してからテスト」ではない。「旧コードで落ちる決定的試験を先に書く → 実装 →
CI → Eviction API/CA 受入」である。完了条件は §5 にまとめた。日付は根拠がないので出さない。

## 1. 区別

| | (1) 受理前の制御 | (2) 削除開始後の制御 |
|---|---|---|
| タイミング | Eviction API が 2xx を返す前。`deletionTimestamp` 未設定 | `deletionTimestamp` 設定後。preStop + grace の内側 |
| 止められるもの | 退避そのもの（429/拒否で CA は scale down を諦めて再試行） | 何も止められない。kubelet は grace 満了で SIGKILL する |
| flare の現状 | **なし**（静的 PDB maxUnavailable 1 だけ。データ適格性を見ない） | **あり**（drain guard: 証明済み follower があれば昇格、なければ master を残して CRITICAL） |

Pod finalizer では kubelet のコンテナ停止を止められない。finalizer が遅らせるのは API
オブジェクトの消去だけで、preStop → SIGTERM → grace 満了で SIGKILL は進む。したがって
finalizer は設計の選択肢にしない。

## 2. Kubernetes / CA の仕様（公式資料に基づく。今回は再取得していない）と実クラスタで確認できた範囲

公式仕様（Kubernetes docs: API-initiated Eviction / Disruptions / Pod Lifecycle、
cluster-autoscaler FAQ）:
- Eviction API（`POST pods/<name>/eviction`）は PDB を評価する。違反するなら 429 を返し、
  許すなら通常の grace 付き削除になる。admission webhook は `pods/eviction` サブリソースの
  CREATE を受け取れる。
- PDB の「healthy」は Pod の **Ready 条件** である（`unhealthyPodEvictionPolicy` で
  NotReady Pod の扱いを選べる）。データの同期状態は PDB には見えない。
- PDB が効くのは Eviction API 経由の退避（CA、`kubectl drain`）だけである。
  `kubectl delete pod`、`kubectl drain --disable-eviction`、kubelet の node-pressure
  eviction、ノード障害、スポット回収には効かない。
- preStop は grace の内側で実行される。grace 満了で SIGKILL。
- CA は PDB を尊重する。`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` の Pod
  がいるノードは scale down 対象外になる。upstream の既定値は
  `--skip-nodes-with-local-storage=true`（emptyDir を持つ Pod のノードは削除しない）、
  `--max-graceful-termination-sec=600`。

実クラスタ（gree-tc-tc-wg-dev-cluster-01）:
- 確認済み（2026-10-13）: `kube-system/cluster-autoscaler-status` があり Running。
  `scaleDown: CandidatesPresent`。10:52Z 頃 master nodes-1 が
  `deleting pod for node scale down` で退避された。pf-dev の PDB は maxUnavailable 1、
  allowed 1（2 Pod とも Ready）。
- **未確認**: TKE CA のバージョンとフラグ。2026-10-14 に Teleport のセッションが切れて
  読めなかった。/data は emptyDir(medium Memory) なのに退避されたので、
  skip-nodes-with-local-storage は実質 false と**推定**するが、確認はしていない。
  11:07:43Z の nodes-0 再作成の原因も未確定（event 期限切れ、operator log ローテーション）。

## 3. 段階ごとの現状

列「CI」は、candidate 16921a5 の full matrix 38338541303（X4 cross-cluster 4-5 以外は
合格）と nix 38338538614 を指す。E2E は kind 上で `kubectl delete pod` を使う。
**Eviction API・`kubectl drain`・CA・PDB の評価を通す試験は一つもない。**

| 段階 | コード | 状態 | 既存の検証と証明範囲 |
|---|---|---|---|
| a. 退避要求の受理判定 | chart `flare-cluster.yaml:571-587` 静的 PDB maxUnavailable 1 | **未実装**（データ適格性での拒否なし。webhook・動的 PDB・readinessGate なし） | なし。PDB を評価する試験もない |
| b. 同期・履歴・コピー適格性の確認 | `StateMachine/FollowEvidence.lean`（judge/classify）、`K8sReconciler.lean` の shapePromotionCandidates | 実装済み。**ただし削除開始後（drain 時）にしか使われない** | wal-recovery / continuous-replication / breaker-migration 群（ContinuousReplication drain 試験、copy-identity 13 の昇格保留→unfit 時の safe stop） |
| c. master 引継ぎ | `K8sReconciler.lean:482-535` handleDrainWithPromotionSingleKey（Terminating master を live proxy に降格し、証明済み follower を昇格） | 実装済み（削除開始後のみ）。昇格条件は lag ≤ `FLARE_FOLLOW_PROMOTE_LAG`（既定 100）で、**write fence と lag 0 までの追いつきはない** | TerminatingPodHandling（役割遷移のみ。データ照合なし）。ContinuousReplication の graceful delete（drain 経由の昇格、epoch 前進、事後書き込み 10 件。**削除中の書き込みは試していない**）。単体: 降格は少なくすることしかない（at-most-one-master の証明）。データ保全の証明ではない |
| d. 削除許可 | なし。preStop は `sleep 60`（chart `flare-cluster.yaml:479-489`、Migration/Provision.lean:268 も同じ sleep） | **未実装**。引継ぎの成否と無関係に削除は進む | — |
| e. 別ノードでの再構築完了 | readinessProbe（chart `:446-476`）: operator が map 上 active にした時だけ Ready。staged rebuild と reserve（`rebuild_blocked`） | 実装済み（Ready ゲートで StatefulSet と PDB が次の Pod を待つ） | continuous-replication-limits の no_space 試験、upgrade 試験 |

### 境界条件の現状

| 条件 | 今起きること |
|---|---|
| 同期先なし（replica が未構築・no_space） | PDB は replica が NotReady なら退避を拒否する（Ready ゲートのため）。ただし replica が Ready（map 上 active）のまま follow が idle や needs_rebuild に落ちた場合、**PDB は退避を許す** → drain guard が昇格を拒否 → master は猶予切れで消える → tmpfs ではデータ全損（CRITICAL `FlareDrainNoSuccessor` が出るだけ） |
| 遅延（lag 1〜100） | drain が昇格する。master が受理済みで follower 未適用の最大 100 エントリは失われうる。「PROMOTION NOT LOSS-FREE」も出ない（証明済みの扱いのため） |
| 遅延（lag > 100）・通信断 | 未証明 → drain guard が拒否 → 上と同じで猶予切れに全損 |
| operator 不在 | drain 自体が起きない。PDB は Ready だけ見るので退避は通る。master は猶予切れで消え、operator が戻った後の dead-node failover で「not loss-free」昇格 |
| 同時退避 | PDB maxUnavailable 1 で直列化される（Ready に限る）。`kubectl delete` やノード障害は対象外 |
| 猶予切れ | 引継ぎ未完でも SIGKILL。延長する仕組みはない（CA の max-graceful-termination-sec も上限） |
| 引継ぎ中の追加 write | Service から外れた旧 master は、保持中の接続の write を新 master へ proxy 転送する。失敗は `proxy_write_dropped` に数えるだけで再送はない。新規接続は Service（pf-dev は Pod 名で固定の selector）の付け替えまで届かない |
| tmpfs 喪失 | 退避された Pod は空で戻り、全量 rebuild が必要。pf-dev 8Gi では reserve 2304MiB で no_space の可能性が高い（未計測） → replica なし運転が続き、Ready にならないので PDB は以後の退避を全部拒否する（安全側だが scale down もできない） |

## 4. 実装方針（最小案）

**原則: 受理前に拒否する層（A）と、受理後に安全に引き継ぐ層（B）の両方が要る。** A だけ
だと判定から実際の終了までの間に状態が変わる（TOCTOU）。B だけだと今と同じで、
引継ぎできなかった時に止められない。

**A. 受理前ゲート（新規）: `pods/eviction` の ValidatingAdmissionWebhook（operator が提供）**
- 対象: objectSelector `app=flare` の flared Pod。`failurePolicy: Fail` で、operator
  不在なら退避を拒否する（fail-closed）。
- 判定（毎回その場で stats を読む。キャッシュは使わない）:
  - 退避対象が master なら、同じ partition に証明済み follower が要る。条件は同 epoch で
    following、観測が新鮮、lag ≤ bound（FollowEvidence をそのまま使う）。
  - 他の flared Pod に Terminating・NotReady・rebuild 中・`rebuild_blocked` があれば拒否
    （同時退避の防止。PDB と二重に掛ける）。
  - FlareMigration 実行中、または history 保留中は拒否する。
  - replica の退避は、master が健全で他に disruption がなければ許可する。ただし再構築先の
    容量見込み（reserve + コピー量 ≤ 利用可能量）を満たさない時は拒否する。
- 代替案は readinessGate または動的 PDB（operator が条件を書く）。operator が止まると
  最後の値のまま固まる（fail-open になりうる）ので、第一案にしない。
- 費用: webhook の TLS 証明書管理（chart への追加）。webhook が落ちている間は、このクラスタの
  ノードの drain・scale down がすべて止まる（意図した fail-closed）。

**B. 受理後の計画的引継ぎ（既存 drain の強化）**
1. flared に write fence を追加する。Terminating master が新規 write を受けず（エラー応答）、
   受理済みを確定させる。
2. operator は follower の applied == master head（lag 0）を確認してから昇格する。
   制限時間は preStop の内側。
3. 間に合わなければ、今の drain guard（master を残して CRITICAL）。ただし A があるので、
   ここに来るのは受理後に状態が急変した場合だけで、それも試験で示す。
4. preStop を `sleep` から「引継ぎ完了で早く終わる待ち」に変える（上限は grace）。

**C. 運用上の前提（pf-dev に固有）**
- 容量: tmpfs 8Gi で全量 rebuild が通ることを実測で示す。通らなければ、A の容量判定で
  replica の退避が常に拒否される（＝ scale down されないので、safe-to-evict false と同じ）。

## 5. 試験と完了条件

**旧コード（16921a5）で決定的に落ちる試験（先に書く）**

| ID | 手順 | 新コードの期待 | 旧コードで落ちる理由 |
|---|---|---|---|
| EV-A1 | follower の追従を止める（NetworkPolicy で切断、または follow 停止）。master を Eviction API で退避する | 429/拒否。`deletionTimestamp` が付かない | PDB は 2 Pod Ready で許可 → 削除開始 |
| EV-A2 | operator を 0 にスケールしてから master を退避する | 拒否（fail-closed） | 許可 → 猶予切れで master が消える |
| EV-A3 | master と replica への eviction を同時に送る | 受理は高々 1 | （PDB で直列化されるので旧も通る想定。回帰防止用） |
| EV-A4 | replica が `rebuild_blocked=no_space` の時に master を退避する | 拒否 | replica が NotReady なら PDB で旧も拒否。Ready のまま follow 不適格なら許可 → A1 と同型 |
| EV-B1 | follower の適用を遅延注入で lag 1〜100 に保ち、書き込み継続中に master を退避する | 応答済み write が新 master に全件ある | lag ≤ 100 で fence なしに昇格するので差分が消える（遅延注入用の knob が要る） |
| EV-B2 | 受理後に follower を切断する（A を通った後の急変） | master は残り、CRITICAL。損失を「loss-free」と報告しない | 現状と同じ挙動の確認。B のタイムアウト経路の回帰防止 |
| EV-E1 | tmpfs の replica を退避する → 再構築 | 完了まで NotReady。その間の 2 件目の退避は拒否 | 旧も PDB で拒否する想定（回帰防止） |

**受入試験（CA を使う。環境と実施には別途承認が要る）**
- kind 上の CA は難しいので、使い捨てクラスタ（承認された環境）で safe-to-evict を外す。
  利用率を下げて scale down を誘発し、次を観測する:
  - (i) 適格性がない時は、CA が eviction を拒否されて scale down を諦める（CA の status と
    event で確認）。
  - (ii) 適格な時は、引継ぎが完了し、応答済み write の欠損が 0。
  - (iii) 再構築が完了する。
- 対象 CA のバージョンとフラグ（skip-nodes-with-local-storage、
  max-graceful-termination-sec、PDB の扱い）を記録する。

**解禁の完了条件（未実装と未検証を分けて書く）**
- 未実装 → 実装済みにする:
  - A（webhook、fail-closed）
  - B1/B2（fence + lag 0 の引継ぎ）
  - B4（preStop の早期終了）
  - C は pf-dev の容量方針
- 未検証 → 検証済みにする:
  - EV-A1/A2/B1 が旧コードで落ちる記録
  - 新コードで EV-* すべて合格（full matrix を 1 回、固定 candidate で）
  - TKE CA のバージョンとフラグの確認
  - CA 受入 (i)〜(iii)
  - 独立レビュー
- どちらか一つでも欠けていれば、safe-to-evict false を外さない。

## 6. レビューで決めてほしいこと

1. A を webhook にする（fail-closed、TLS 管理の費用あり）か、readinessGate/動的 PDB にする
   （安価だが operator 停止時に固まる）か。
2. B1 の write fence の間、クライアントに見える書き込みエラー（数秒）を許容するか。
3. pf-dev で解禁を目指すか（容量の実測が前提）。目指さないなら safe-to-evict false を恒久とし、
   ノード保守は人手の計画手順にする。
