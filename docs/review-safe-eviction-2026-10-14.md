# 安全な自動退避（safe-to-evict 解除）— 調査結果と実装方針（レビュー依頼 v2）

2026-10-14。調査対象は `d9d9961`（コードは candidate `16921a5` と同一）。
**本書は設計レビューへの再提出であって承認ではない。** annotation 変更・eviction・drain・
Pod 削除・クラスタ変更は一切行っていない。pf-dev 準備と既承認の操作（moc2-k8s #9600 を
含む）は別扱いで、本書はそれを拡張も中断もしない。**安全な自動退避の CI 証拠はまだ
存在しない**（e6aa0ff とこの改訂は docs のみ）。

## v2 の変更点（e6aa0ff のレビュー changes_requested への対応）

| 指摘 | 対応 |
|---|---|
| [P1] 許可後に fence/catch-up を始める設計では、許可直後の replica 断で grace 満了時に旧 master が消える。EV-B2「master は残る」は map 上だけで、実現できない | §4 を作り直した。計画退避の準備（全 mutation 入口の fence、受理済み in-flight の排出、固定 barrier LSN、同一 lineage の別ノードでの適用確認、master 交代と旧 master が write を受けないことの確認）を**削除許可より前**に完了させる。初回 eviction は拒否し、非同期 prepare の完了後の再要求だけを許可する。preStop は後始末に限る。許可後の独立故障は保証範囲外として §4.6 に明記した。旧 EV-B2 は削除した |
| [P1] objectSelector `app=flare` は通常の Eviction を取り逃す | §4.2。admission の object は policy/v1 Eviction（通常 metadata.name/namespace だけで、Pod のラベルを持たない）。namespaceSelector で管理 namespace の `pods/eviction` を全部受け、対象 Pod を名前から UID 付きで解決して所属を判定する。Unknown は拒否、非対象は許可（明記）。ラベルなしの標準 `kubectl drain` と素の Eviction body が webhook に届く試験を必須にした |
| [P1 設計欠落] prepare/grant の束縛、lease・再起動・同名置換・重複・キャンセル・期限切れ、fence 解除、遅延到着、admission timeout、dryRun、後段 PDB 拒否、応答喪失、static PDB、容量 | §4.3〜4.5 に規定した |
| [P2] 「データ全損」「最大 100 件損失」の断定、同 epoch 条件、pre-proxy と post-proxy の混同、CA フラグの推定 | §3 を書き直した |
| 順序の書き方 | 「実装してからテスト、ではない」という書き方を撤回した。ユーザーの「まず必要な制御を実装し検証する」は正しい。決定的試験はその実装の一部として先に書く |

## 1. 結論

- **今の flare には、Pod に `deletionTimestamp` が付く前にデータ適格性で退避を止める制御がない。**
  - preStop は `sleep 60`（chart `flare-cluster.yaml:479-489`、`Migration/Provision.lean:268`）。
  - PDB は静的な maxUnavailable 1 で、Pod の Ready だけを数える。
- 既存の drain（`K8sReconciler.lean:482-535`）は削除開始後の制御である。猶予（pf-dev: preStop 60 s、grace 90 s）の中で昇格を試みるが、削除そのものは止められない。
- safe-to-evict false を外す前に、次の 2 つが要る:
  - 削除許可の前に計画退避の準備を完了させる仕組み（§4）
  - それを旧コードとの対照と Eviction API/CA で示す試験（§5）
- 日付は根拠がないので出さない。完了条件は §5.3。

## 2. 仕様

### 2.1 公式資料（2026-10-14 に参照）

- https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/
  - Eviction の body は `{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":…,"namespace":…}}`。
  - API サーバは admission check の後、200（Pod を削除）、429（PDB またはレート制限）、500（誤設定）のいずれかを返す。
  - 許可されると Pod に deletion timestamp と grace が付く。grace 満了で kubelet が強制終了する。
- https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
  - objectSelector は admission に送られる object のラベルで判定する。Pod のサブリソース（`pods/eviction`）では Pod 本体と照合しない。Pod を扱うなら namespaceSelector か rules を使う。
  - 既定の timeout は 10 s で、短くすることが推奨されている。timeout は failurePolicy に従う。
  - sideEffects は `None` / `NoneOnDryRun`。
- 同 Disruptions / Pod Lifecycle（今回は再取得していない）:
  - PDB の healthy は Ready 条件である。
  - PDB が効くのは Eviction API だけである。`kubectl delete pod`、`drain --disable-eviction`、kubelet の node-pressure eviction、ノード障害は対象外。
  - Pod finalizer は API オブジェクトの消去を遅らせるだけで、kubelet の preStop → SIGTERM → 猶予満了の SIGKILL は止めない。**finalizer を保護手段にしない。**

### 2.2 実クラスタ（gree-tc-tc-wg-dev-cluster-01）

- **確認済み（2026-10-13）:**
  - `kube-system/cluster-autoscaler-status` が Running、`scaleDown: CandidatesPresent`。
  - 10:52Z 頃、master nodes-1 が `deleting pod for node scale down` で退避された。
  - pf-dev の PDB は maxUnavailable 1、allowed 1（2 Pod とも Ready）。
- **未確認:**
  - TKE CA のバージョンとフラグ（`--skip-nodes-with-local-storage`、`--max-graceful-termination-sec`）。
  - Memory medium の emptyDir をローカルストレージ扱いから外す条件があるか。
  - `safe-to-evict-local-volumes` などの annotation の扱い。
  - 2026-10-14 は Teleport のセッション切れで読めていない。
- **e6aa0ff の「skip-nodes-with-local-storage は実質 false と推定」は撤回する。** tmpfs の Pod が退避された事実だけでは、フラグの値を区別できない（版や除外条件による）。
- 11:07:43Z の nodes-0 再作成の原因は未確定（event 期限切れ、operator log ローテーション）。

## 3. 現状（段階別・境界条件）

### 3.1 段階別

列「CI」は、candidate 16921a5 の full matrix 38338541303（X4 cross-cluster 4-5 以外合格）と nix 38338538614 を指す。E2E はすべて `kubectl delete pod` を使う。**Eviction API・`kubectl drain`・CA・PDB の評価・admission を通す試験は一つもない。**

| 段階 | コード | 状態 | 既存検証と証明範囲 |
|---|---|---|---|
| a. 退避要求の受理判定 | chart `flare-cluster.yaml:571-587` 静的 PDB | **未実装**（データ適格性での拒否なし） | なし |
| b. 同期・履歴・コピー適格性 | `StateMachine/FollowEvidence.lean`（following、`repl_follow_source_epoch` が master の `rocksdb_source_epoch` と一致、観測鮮度、`head − applied ≤ promoteLag`）、shapePromotionCandidates | 実装済み。**削除開始後の drain と failover でしか使われない**。判定は epoch 文字列（番号:uuid）と LSN 差で、authoritative history record の holder、copy identity（`rocksdb_copy_id`、`rocksdb_copy_identity_consistent`、`rocksdb_rebuilt_from_master_id`）、Pod UID、boot id の束縛は判定に含まれない | continuous-replication / breaker-migration 群（drain 経由昇格、copy-identity 13 の昇格保留と unfit 時の safe stop） |
| c. master 交代 | `K8sReconciler.lean:482-535`（Terminating master を live proxy に降格し、証明済み follower を昇格） | 削除開始後のみ。**write fence なし、barrier なし**。lag ≤ 100（LSN 差）で昇格する | TerminatingPodHandling（役割遷移のみ、データ照合なし）。ContinuousReplication の graceful delete（drain 経由の昇格、epoch 前進、事後の書き込み 10 件。**削除中の書き込みは試していない**）。単体の証明は at-most-one-master で、データ保全の証明ではない |
| d. 削除許可 | なし（preStop = sleep） | **未実装** | — |
| e. 別ノードでの再構築完了 | readinessProbe（chart `:446-476`）: map 上 active で Ready。staged rebuild と reserve | 実装済み（Ready ゲートで StatefulSet と PDB が待つ） | continuous-replication-limits の no_space 試験、upgrade 試験 |

### 3.2 境界条件（今のコードで、Eviction API により master が退避された場合）

前提: replica は PDB 上 Ready（map 上 active）。WAL follow の適格性は Ready に反映されない。

| 条件 | 今起きること（損失の範囲を分けて書く） |
|---|---|
| replica が証明済み（lag ≤ 100、同 epoch、新鮮） | drain が猶予内に昇格する。**fence がない**ので、昇格時点で旧 master が受理済み・replica 未適用だった変更は新 master に無い。LSN 差 100 は損失件数の上限ではない。1 件の client write が複数の sequence を使うことがあり、reaper の削除なども sequence を消費する。観測後、降格が flared に届くまでに旧 master が受理する write も加わる |
| replica が未証明（lag > 100、切断、鮮度切れ） | drain guard が昇格を拒否し、旧 master は猶予満了で消える（CRITICAL `FlareDrainNoSuccessor`）。その後は failover になる。replica の既存コピーは残るので、損失は**旧 master だけが持っていた変更**に限られる。<br>・backlog が `failoverMaxLag`（既定 100000）以内なら failover が昇格し、`PROMOTION NOT LOSS-FREE` と記録する。<br>・それを超えると、PVC なら旧 master の帰還を待つ。tmpfs では旧 master が空で戻るので待つ相手がなく、replica が最後の手段で据えられる（not loss-free と記録）。<br>・その間、partition は一時的に masterless になる。<br>・**partition 全損は、データを持つコピーが旧 master だけだった場合（replica が空・再構築中など）に限る** |
| operator 不在 | drain は起きない。PDB は Ready だけを見るので退避は通る。損失の範囲は前行と同じで、failover は operator 復帰後になる |
| 同時退避 | PDB maxUnavailable 1 で直列化される（Ready に限る）。`kubectl delete` とノード障害は対象外 |
| 猶予切れ | 引継ぎの成否と無関係に SIGKILL。延長はできない（CA 側にも上限がある） |
| 交代前後の書き込み | 経路で結果が異なる。<br>・**pre-proxy**（非 master が client write を master へ転送してから応答）: 転送失敗は client に `SERVER_ERROR proxy error`（`op_set.cc:123-128` ほか）。ただし `noreply` の write は失敗が client に見えない。<br>・**post-proxy**（master がローカルに適用して client に成功を返した後、replica へ非同期転送）: 失敗は `proxy_write_dropped` に数えるだけ（`cluster.cc:1858-1864`、宛先が proxy になった場合 `handler_proxy.cc:120-131`）。client は成功を受け取り済み。<br>・**cross-cluster 転送**（`cluster_replication.cc:238-249`）: 同じく応答済みで、宛先側には届かない。<br>・新規接続は Service（pf-dev は Pod 名の selector）が付け替わるまで届かない |
| tmpfs 喪失 | 退避された Pod は空で戻り、全量 rebuild が要る。pf-dev 8Gi では reserve 2304MiB で no_space の可能性がある（未計測）。その間は単一コピーで運転し、Ready にならないので PDB はそれ以後の退避を拒否する |

## 4. 設計案

### 4.1 原則

1. **データ安全に必要な作業はすべて削除許可の前に終える。** 許可時点で、退避対象の Pod は
   いかなる partition のデータ責任も持っていない（proxy）。旧 master が書き込みを受けない
   ことも確認済みである。preStop は後始末（接続の排出）だけをする。
2. **初回の eviction は拒否する。** 拒否が、非同期 prepare の開始要求を兼ねる。CA と
   `kubectl drain` は拒否された eviction を再試行する。再要求が来た時点で準備済みなら許可する。
3. **webhook 内では待たない。** admission timeout（既定 10 s、推奨は短く）の中で catch-up は
   しない。webhook は永続状態と現在の Pod を読んで判定し、必要なら要求を記録するだけである。
4. **static PDB をデータ安全の予約とみなさない。** 残すが、Ready 直列化の追加の層にすぎない。
5. **保証範囲を有限にする**（§4.6）。

### 4.2 捕捉（admission）

- ValidatingWebhookConfiguration:
  - rules: `CREATE` の `pods/eviction`（policy/v1 と v1beta1）
  - **namespaceSelector**: FlareCluster を持つ管理 namespace（ラベルで指定）
  - objectSelector: **使わない**
  - `failurePolicy: Fail`
  - `sideEffects: NoneOnDryRun`
  - `timeoutSeconds`: 短く（例 5）
- 判定手順:
  1. `request.name`/`namespace` から Pod を読み、UID・ラベル・所属 FlareCluster・ownerReference を得る。読めなければ **Unknown → 拒否**。
  2. Eviction の `deleteOptions.preconditions.uid` があれば、Pod の UID と一致することを確認する（不一致は拒否）。
  3. **flared Pod でない場合**（operator、backup Job など）: 許可。operator の退避がこの仕組みに与える影響は §4.6 に書く。
  4. **flared Pod の場合**: §4.3 の grant を照合する。有効な grant がなければ拒否する（理由をメッセージに入れる）。dryRun でなければ、退避要求を記録する。
- 応答は拒否時 403（メッセージ付き）、許可時 allowed。webhook の許可の後でも、API サーバの PDB 判定で 429 になりうる（§4.5）。

### 4.3 prepare と grant

**永続状態**（operator の CR status、例: FlareCluster status の `disruption`。in-memory にしない）。1 クラスタあたり同時に 1 件:
```
request:  { id, podName, podUID, requestedAt, expiresAt }
prepare:  { phase: Requested | Fencing | Draining | Barrier | Applying | Switching | Granted | Aborted,
            partition, oldMasterKey, successorKey, successorPodUID,
            bootIdOld, bootIdSuccessor, historyEpoch (番号:uuid), historyRecordHolder,
            copyIdSuccessor, barrierLSN, fenceToken, operatorLeaseHolder, operatorLeaseEpoch }
grant:    { podUID, bootId, historyEpoch, notBefore, expiresAt, requestId }
```

**prepare の手順**（operator の reconcile で非同期に実行。webhook ではない）:

退避対象が master の場合:
1. **事前条件**（すべて同じ pass の新鮮な読み取りで確認）:
   - 他に disruption がない。
   - FlareMigration 中でも history 保留中でもない。
   - 後継候補が following、epoch 一致、authoritative history record と lineage が一致、copy identity が consistent。
   - 後継の Pod UID、ノード、boot id は退避対象と異なる。
   - `rebuild_blocked` なし。
2. **fence**: 旧 master の全 mutation 入口を閉じる。対象:
   - client の set/add/replace/append/prepend/cas/touch/incr/decr/delete/flush_all
   - 他ノードからの proxy write
   - cross-cluster からの受信 write
   - expire reaper の削除
   - orphan purge
   - dump/snapshot の受信
   - restore

   閉じた入口は pre-proxy 方式で client にエラーを返し、失敗が見えるようにする。fence は
   flared の新機能で、`fenceToken` と TTL を持つ。operator が更新しなければ自動で解除され、
   master は元に戻る。
3. **in-flight の排出**: fence より前に入口を通過した mutation が全て完了する（flared の in-flight カウンタが 0）。
4. **barrier**: その時点の `rocksdb_latest_sequence_number` を `barrierLSN` として固定する。
5. **適用確認**: 後継の `repl_applied_lsn ≥ barrierLSN` を確認する。同じ history epoch、同じ lineage、記録した後継の Pod UID と boot id のまま、別ノード上で。
6. **交代**: 後継を昇格し、旧 master を proxy に降格する（map 配布）。続けて次を確認する:
   - 旧 master 自身が proxy 役を報告し、ローカル write を受けない（fence は降格の確認まで保持）。
   - 後継が master として write を受ける。
   - Service と endpoints が後継を指している。
7. **grant を発行する**（UID、boot id、history epoch、期限に束縛）。

退避対象が replica の場合:
- 事前条件は、master が健全、他に disruption がない、対象が partition の唯一の data-bearing コピーではない。
- fence と交代は不要。
- 許可後は単一コピー運転になる（§4.6 の可用性限界）。

**許可（再要求時の webhook）**: 次をすべて満たす時だけ許可する。
- grant が存在し、期限内。
- 現在の Pod UID と boot id が grant と一致。
- 現在の history epoch が grant と一致。
- 対象 Pod が今も proxy（いかなる partition も持たない）。
- 後継が今も master で健全。

一つでも外れれば拒否する（grant は無効化し、再 prepare になる）。

### 4.4 中断・期限・競合

| 事象 | 扱い |
|---|---|
| prepare 中の通信断・operator leader 喪失・operator 再起動 | prepare 状態は永続化してある。新 leader は `operatorLeaseEpoch` の不一致を見て、その prepare を **Aborted** にする。<br>・**交代前**: fence を明示的に解除する。届かなくても TTL で解除される。旧 master は master のまま、退避は拒否のまま。<br>・**交代後**: 旧 master は proxy として残り、follower に戻す（同一 lineage で barrier まで適用済みなら追従を再開、そうでなければ rebuild）。<br>Pod は残る。grant は出ていない |
| 後継が prepare 中に不適格になった（断、遅延、再起動、boot id 変化） | Aborted にし、fence を解除する。退避は拒否を続ける |
| Pod の同名置換（UID 変化） | 束縛している UID が不一致なので、grant と prepare を破棄する |
| 重複要求（同じ Pod） | 冪等。既存の request を使う |
| 同時要求（別の Pod） | 2 件目は「別の disruption が進行中」で拒否 |
| 準備後のキャンセル・期限切れ（requester が再試行をやめた、CA が scale down を諦めた） | grant の期限切れで、旧 master（proxy）を follower に戻す（前々行と同じ）。役割は交代したまま戻さない（戻すなら、それ自体を計画交代として扱う） |
| 許可済みの eviction が遅れて届いた | 許可時の判定は現在の状態で再評価する（§4.3）。期限切れ・役割変化・UID 変化なら拒否 |
| fence の解除とロールバック | 解除は operator の明示解除か TTL 満了。解除後は旧 master が通常どおり受ける。交代前の中断では役割を変えない |
| dryRun | 記録しない（`NoneOnDryRun`）。判定だけを返す |
| 後段の PDB 拒否（webhook 許可 → API サーバの PDB 判定で 429） | 何も壊れない。対象は既に proxy。grant は期限まで有効で、再試行で通る |
| 応答の喪失（webhook が許可したが API サーバに届かない） | failurePolicy Fail で拒否扱いになる。<br>削除が成立したのに requester に結果が届かない場合も、operator は **実際の Pod 状態**（UID と deletionTimestamp）を真実として再調停する。webhook の判定履歴は真実として使わない |
| 許可後、削除前に状態が変わった（例: 後継が故障し、旧 master がまた昇格された） | admission 後の TOCTOU は残る。削除開始後は既存の drain guard（type 2）にフォールバックする。保証範囲外（§4.6）として扱い、検知を試験する |

### 4.5 容量

- 観測時の空き容量は、退避後に再構築が成功する保証にならない。再構築先のノードと時点が未確定だからである。
- 選択肢は 2 つ（レビューで選ぶ）:
  - (a) **make-before-break**: 退避の前に交代先を別ノードに事前確保する。追加の replica を構築して適格化してから、元を外す。容量の主張ができるのは、この方式だけ。
  - (b) **可用性限界として分離**: 退避後は単一コピー運転になる。再構築が容量不足で止まれば単一コピーのまま。次の退避は「data-bearing コピーが 1 つ」で拒否される（データ安全側）。冗長性の回復は保証しない。

### 4.6 保証範囲

**保証する（試験で示す）**: Eviction API 経由の計画退避そのものによって、成功応答済みの write は失われない。
- 許可の時点で、退避対象は partition の責任を持っていない。
- 成功応答済みの全 write が、別ノードの同一 lineage のコピーに適用済みである。
- replica の退避では、master が全データを持ったまま残る。

**保証しない（明記する）**:
- 許可後に起きる独立故障: 残ったコピーのノード故障、単一コピー期間の master 喪失など。
- PDB と admission を通らない経路: `kubectl delete pod`、`drain --disable-eviction`、node-pressure eviction、ノード障害、スポット回収。
- 許可と削除の間の TOCTOU（§4.4 最終行。検知のみ）。
- 容量方式が (b) の場合の冗長性回復。
- 無制限の故障耐性は約束しない。
- operator の退避: webhook は operator が提供するので、operator が全滅している間は flared の退避がすべて拒否される（fail-closed）。operator は複数レプリカにして、自分の PDB を持つ前提。

## 5. 試験と完了条件

### 5.1 決定的試験（旧コード 16921a5 と対照する）

| ID | 手順 | 新コードの期待 | 旧コード |
|---|---|---|---|
| EV-01 | ラベルを付けない素の policy/v1 Eviction body と、標準の `kubectl drain`（Eviction API 経路）を flared master に送る | webhook が呼ばれる（webhook 側の受信記録）。準備がないので拒否、`deletionTimestamp` は付かない | 許可 → 削除開始（落ちる） |
| EV-02 | 初回要求の後、prepare 中に後継の通信を切る | Aborted、fence 解除、Pod は残る、再要求は拒否 | 初回で削除（落ちる） |
| EV-03 | prepare 中に operator leader を失わせる（Pod 削除、または lease を奪う） | Aborted、fence は TTL で解除、Pod は残る | 同上（落ちる） |
| EV-04 | prepare の完了後に再要求する | 許可。退避時に対象は proxy。後継は master | 準備がないので許可（期待する状態が無く、落ちる） |
| EV-05 | 古い UID の grant（同名置換後）、期限切れ grant、別の Pod への同時要求、dryRun、`preconditions.uid` の不一致 | すべて拒否。dryRun では状態が変わらない | 許可（落ちる） |
| EV-06 | webhook は許可するが PDB が 429 を返す状況を作る（他の Pod を NotReady にする） | 状態が壊れない。grant が残り、再試行で許可される | （新規機能の試験） |
| EV-07 | 連続書き込み（成功応答を全件記録）の最中に、prepare → 許可 → 退避 → 再構築を行う | 成功応答済みの全 write が新 master にある。fence 中の write は client にエラー応答 | fence がなく欠損しうる。決定化するには後継への適用遅延の注入 knob が要る（実装項目） |
| EV-08 | 再構築中（NotReady、または `rebuild_blocked`）に次の退避を送る | 拒否 | replica が NotReady なら PDB で拒否。Ready のまま follow 不適格なら許可（落ちる） |
| EV-09 | fence の網羅: §4.3 の各 mutation 入口から fence 中に書き込む | 全入口がエラー応答し、適用されない。reaper と orphan purge は止まる | fence がない（落ちる） |

### 5.2 受入（CA を使う。環境の作成と実施には別途承認が要る）

- 使い捨てクラスタで safe-to-evict を外し、scale down を誘発して、次を観測する:
  - (i) 初回は拒否され、prepare が完了した後の再試行で許可される。
  - (ii) 成功応答済み write の欠損が 0。
  - (iii) 再構築が完了する（容量方式 (a) の場合）。または単一コピーで次の退避が拒否される（(b) の場合）。
- 対象 CA のバージョンとフラグ、Memory emptyDir の扱いを記録する。

### 5.3 解禁の完了条件（未実装と未検証を分けて書く）

- **未実装 → 実装済み:**
  - webhook（§4.2）
  - prepare と grant の永続状態と手順（§4.3）
  - 中断の扱い（§4.4）
  - flared の fence（TTL 付き、全入口）、in-flight カウンタ、barrier
  - 適用遅延の試験用 knob
  - preStop の後始末化
  - 容量方式の決定と（a なら）実装
- **未検証 → 検証済み:**
  - EV-01〜09 の旧コードでの失敗記録
  - 新コードでの全合格（固定 candidate で full matrix 1 回）
  - TKE CA の版、フラグ、Memory emptyDir の扱いの確認
  - CA 受入 (i)〜(iii)
  - 独立レビュー
- 一つでも欠ければ safe-to-evict false を外さない。

## 6. レビューで決めてほしいこと

1. 容量方式: (a) make-before-break（容量を保証できるが、一時的に 3 コピー分の資源が要る）か、(b) 可用性限界として分離するか。
2. fence 中にクライアントに見える書き込みエラー（barrier の適用待ちの数秒）を許容するか。
3. pf-dev で解禁を目指すか。目指さないなら safe-to-evict false を恒久とし、ノード保守は人手の計画手順にする。
