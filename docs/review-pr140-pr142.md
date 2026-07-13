# レビュー資料: PR #140 (Flare Operator) / PR #142 (RocksDB backend)

- 対象: [gree/flare#140](https://github.com/gree/flare/pull/140) / [gree/flare#142](https://github.com/gree/flare/pull/142)
- 作成日: 2026-07-12 / 想定読了時間: 約30分
- 本資料の file:line は `flare-operator` ブランチの working tree 基準。**すべての根拠箇所は資料作成時に実コードで確認済み**(未確認の項目は「⚠要確認」と明示)

> **修正状況(2026-07-12 更新)**: 本資料の主要指摘は `flare-operator` ブランチ上で修正済み。
> - `f68671c` — F-1(iter_begin ロックリーク)/ F-2(truncate 非排他)/ `_master_id` 競合を修正(C++)
> - `141d725` — R-1(FSM-vs-TCP 二重 master 競合)を `mergeClusterState` の重複 master 修復で解消(Lean)
> - `968e423` — モデルの no-op reconcile を本番の `assignProxiesPure` に接続、`NodeDie`(failover)ステップ追加、非自明性定理・failover 定理・R-1 回帰定理を追加、ドキュメントの誇張を修正
> - `0555e53` — **PVC オプション**(`ClusterConfig.usePvc`)+ 新 E2E スイート `pvc-data-survival`(master+slave **同時死**からのデータ生還を per-key 検証 — emptyDir では原理的に不可能なケース)
> - `69d49ac` — **R-2: ゾンビ master 復活によるデータ喪失を発見・修正**。flared が再起動して pod が生存リストから消えないまま `node add` 再登録すると、failover が一度も走らずに空のゾンビが Master/Active に返り咲く経路がモデルで再現された(修正前 scenario4)。`autoAssign` に「master 不在パーティションは Active slave を優先昇格」のガードを追加。同時に scenario2 トレースの Ready 連鎖が空回りしていた問題(step 10-17 が no-op)も修正
> - `3464ee9` — **初の一般定理**: `demoteDuplicateMasters_atMostOne` / `mergeClusterState_atMostOneMaster` — シナリオ限定でなく**任意の入力**に対して「commit される nodeMap に同一パーティションの master は高々1」を帰納法で証明(sorry なし)
>
> §3.5 / §4.6 / §5 の各所に修正内容を追記済み。E2E(kind 環境)での再実行は未実施 — CI で確認が必要。
>
> **未カバー領域の充填(2026-07-13)**: レビューで挙げた8つの未カバー項目のうち7つを実装済み:
> - `b0d62f1` — G1/G2/G7 を PVC 化し emptyDir 起因の SKIP を実アサートに
> - `9a75a10` — Prepare 固着 watchdog(`flare_operator_nodes_prepare_stuck`、alert-only)+ **lease fence**(TCP broadcast 直前に保持再確認 — 二重リーダー窓の残余は送信中1回分のみ、ドキュメント化)
> - `9d736d3` — merge の一般定理3本追加: 登録消失なし・キー列保存・**死者復活なし**(すべて任意状態対象、sorry なし)
> - `42151c4` — flared `reload()` が rocksdb WAL 系4オプションを SIGHUP で hot-reload(G12-5 の根本修正)+ `repl_sync_wal` パーサの不正入力テスト8件(F11)
> - `dda75dd` — truncate/set 並行性テスト + orphan token TTL 失効テスト
>
> 未了は「一般帰納証明 `stepPreservesAtMostOneMaster` の sorry 解消」のみ(数日規模の証明工数。commit 境界の一般定理でリスクの大半はカバー済み)。
>
> **第2ラウンド: バックアップ機能と CI 駆動の実バグ修正(2026-07-13 追記)**
>
> | コミット | 内容 |
> |---|---|
> | `b31cac8` `6c7bc23` | **バックアップ/リストア新設**: flared `backup` op(RocksDB Checkpoint、世代管理、path-traversal ガード)+ S3 退避 CronJob + RESTORE フック + runbook(docs/BACKUP_RESTORE.md)。**E2E で「flush_all 全損 → 全キー完全復元」を実証済み(PASS)** |
> | `5c40091` → `fc51cf0` | **SIGHUP タイミングバグ**(ConfigMap の kubelet 伝播前に SIGHUP → 設定が無言で失われる本番バグ)を発見・修正。初版の同期待ちが reconcile ループを停止させる退行を起こしたため、tick 分割の非ブロッキング再検証方式に再設計 |
> | `31daf5c` | **WAL 増分同期が構造的に一度も動いていなかった**ことを発見(クライアントは cluster-replication 専用ハンドラのみに存在)。`handler_reconstruction` に WAL-first 分岐を追加(厳格ゲート + 非破壊フォールバック) |
> | `2b4b028` | **鶏と卵の発見・修正**: `__flare_repl_last_lsn` は WAL 同期でしか書かれず、WAL 同期は LSN>0 が条件 → full dump 完了時に master の **dump 開始前 LSN** を種付け(開始後だと取り漏らし=データロス方向。開始前の重複再生は WAL が絶対値 Put のため収束) |
> | `aa9c055` | **ゴースト昇格によるデータ喪失(CI で実測した flake)を修正**: pod 高速再作成で dead 検出が窓を外すと「死んだ pod の Slave/Active エントリ」が残り昇格されていた → 昇格候補に pod 生存チェックを必須化。flake を再現する scenario5 で3定理を機械検証 |
> | `d27797d` | CI: push/PR の二重実行を廃止(同一コードで pass/fail が割れる混乱の解消) |
> | `357d745` | E2E: G12/G5 は設定反映チェーン(伝播→再SIGHUP→reload)を最大240秒待つ方式に、G2 は TTL が再オープン必須のため再起動適用方式に |
>
> **CI 実績**: 全20スイート117テストの green を一度達成(run 29218569229)。その後の G 群深掘りラウンドで G2 の restart 方式が再登録チャーンを誘発する退行を検出(修正中)。G1 は「WAL-first が実際に発火してフォールバック」まで前進。
>
> **本番前の残課題(コード外)**: ステージング障害注入 / 監視アラート定義 / Runbook 整備 / canary 計画(§詳細は前回報告参照)。

---

## 1. サマリ

| | PR #142 `feature/rocksdb` | PR #140 `flare-operator` |
|---|---|---|
| 内容 | RocksDB ストレージバックエンド + WAL ベース増分レプリケーション (C++) | Lean 4 製 Kubernetes operator(flarei 置き換え)+ 形式検証 + E2E |
| 規模 | +7,371 / −30、35ファイル | +21,611 / −22、122ファイル |
| 関係 | — | **#142 を包含する**(feature/rocksdb を merge 済み) |

**レビュー順の推奨**: 先に #142 を確定させてから #140 を見る。#140 の diff の大半は `flare_operator/`(Lean、新規追加のみ)で、既存 C++ への変更は #142 由来。

**結論(推奨)**:

- **#142**: 設計は堅実(全エラーが非破壊的 full dump へフォールバック、LSN と適用データの原子性を確保)。レビューで確認した並行性バグ2件(§3.5 F-1, F-2)と `_master_id` 競合は **`f68671c` で修正済み**。CI(Linux ビルド + E2E)通過を条件に approve 可。
- **#140**: master 一意性とフェイルオーバー時のデータ保全は多層的に設計され、E2E(data-survival-failover)で回帰検知される。レビューで発見した bootstrap 時の二重 master 競合(§4.6 R-1)は **`141d725` で修復ロジック追加済み**(機械検証付き)。形式検証のモデル乖離(§5)も **`968e423` でモデルを実装に接続**し、failover を含むシナリオ証明と非自明性チェックを追加、ドキュメントの誇張を修正済み。**一般帰納証明(`sorry`)と真の並行性の検証は未了**であり、安全性の主たる根拠は引き続き「実装 + E2E + シナリオ証明(回帰カナリア)」。CI 通過を条件に approve 可。

**重要指摘トップ5**(詳細は各節。✅ = 修正済み):

1. ✅ **[#142/バグ] `iter_begin()` の rdlock リーク** — busy 時に `_mutex_wholelock` を保持したまま return(`storage_rocksdb.cc:780-784`)→ `f68671c` で修正
2. ✅ **[#142/バグ] `truncate()` が排他なしで全キー削除** — 並行 `set()` と競合(`storage_rocksdb.cc:735-775`)→ `f68671c` で修正
3. **[#140/設計の要] master failover は「生きた slave の昇格」** — 空の再作成 pod を master にしない(`K8sReconciler.lean:213-246`)。データ保全の核心。`968e423` で failover のシナリオ証明(`scenario3_*`)も追加
4. ✅ **[#140/重要] 形式検証は実装と乖離していた** — 証明対象モデルの reconcile ステップが **no-op** で、看板の `scenario2_verified` はほぼ自明な検証だった(§5)→ `968e423` でモデルを本番関数(`assignProxiesPure` / `handleFailoverWithPromotion`)に接続し、非自明性カナリア定理を追加。**一般帰納証明と並行性は未検証のまま**(明記済み)
5. **[#142/確認] WAL sync は full dump と違い per-key のパーティションフィルタをしない** — orphan キーがコピーされる設計で、`orphan_scan`/`orphan_purge` で事後清掃する前提(§3.4)。設計合意事項として残る

---

## 2. アーキテクチャ全体像

### 2.1 Operator(#140): flarei を置き換える構成

```
                        ┌──────────────────────────────────────────┐
                        │  Flare Operator (Lean 4, single leader)  │
                        │  - Leader election: K8s Lease            │
  FlareCluster CRD ───▶ │  - Reconcile FSM (tick every 5s)         │
  (partitions,          │  - TCP server :12120  (node add/state)   │◀── flared が登録
   replicas, rocksdb)   │  - Metrics :9090 / Health :8080          │
                        └───────┬──────────────────┬───────────────┘
                                │ kubectl apply    │ TCP :12121 "node sync"
                                ▼                  ▼ (topology push)
                     ConfigMap {cr}-node-map   StatefulSet {cr}-nodes
                     (nodeMap 永続化 =          ┌────────┬────────┬─────┐
                      operator 再起動時の復元元) │ flared │ flared │ ... │
                                               │ pod-0  │ pod-1  │     │
                                               └────────┴────────┴─────┘
```

- operator が **flarei(C++ index server)の代替**。flared は port 12120 の operator に `node add` / `node state` を送り、operator が全ノードへ port 12121 でトポロジーを push する(`Server/TcpClient.lean:57-102`)
- クラスタ状態は ConfigMap に serialize され、operator 再起動時に reload される(`Main.lean:914-922`)
- 以下、operator のファイルパスは `flare_operator/FlareOperator/` からの相対

### 2.2 RocksDB レプリケーション(#142): 3フェーズ

```
slave (destination)                    master (source)
      │  Phase 1: "meta features"           │
      │───────────────────────────────────▶ │  op_meta.cc:74-324
      │◀─ "OK rocksdb_wal=1 master_id=…" ── │  (legacy 節点は ERROR → Phase 3 へ)
      │  Phase 2: "repl_sync_wal <lsn> <id>" │
      │───────────────────────────────────▶ │  op_repl_sync_wal.cc:119-256
      │◀─ LSN/BATCH ストリーム … END ─────── │  (master_id 不一致/lsn_purged/
      │     WriteBatch+LSN を原子的に適用    │   lsn_ahead/batch過大 → エラー応答)
      │  Phase 3: full dump (fallback)      │
      │◀────────── 全キー op_set ─────────── │  handler_dump_replication.cc:179-247
```

- オーケストレーションは `handler_dump_replication.cc`(Phase 1: :102、Phase 2: :114-175、Phase 3: :179-)。**Phase 2 のあらゆる失敗は Phase 3(非破壊)へフォールバック**(:155-175)
- 旧バージョン混在でも安全: legacy flared は `meta features` に 1 行 `ERROR` を返すだけでプロトコルの行同期が保たれる

---

## 3. PR #142: RocksDB backend + WAL replication(重点: データ保全)

### 3.1 storage 抽象への組み込み

- `src/lib/storage.h:89` に `type_rocksdb` を追加。`flared.conf` の `storage-type = rocksdb` で選択
- 実装は `src/lib/storage_rocksdb.h`(~340行)/ `storage_rocksdb.cc`(~1055行)。既存 `storage` インターフェース(set/get/remove/incr/iter/truncate/count)を実装し、削除済みキーのバージョン継続のためのヘッダキャッシュは `storage_tcb` と同じ方式
- `--with-rocksdb` なしのビルドには RocksDB コードが入らない(後方互換)

### 3.2 データ保全の核心: LSN とデータの原子的適用

slave が WAL バッチを適用するとき、**データと「どこまで適用したか」の記録を単一 WriteBatch で書く**。クラッシュしても両者がズレない(ズレると次回 sync で同じ範囲を再適用し、`incr` のような非冪等操作が壊れる)。

```cpp
// src/lib/storage_rocksdb.cc:925-950 (apply_batch_with_lsn)
rocksdb::WriteBatch merged(batch.Data());
string lsn_value = boost::lexical_cast<string>(master_lsn);
merged.Put(kReplLastLsnKey, lsn_value);            // LSN marker appended
this->_db->Write(this->_write_options, &merged);   // atomic commit
```

予約キー(`__flare_repl_last_lsn`, `__flare_repl_master_id`)はユーザー操作・iteration・dump から隠蔽される(`is_reserved_key()`, `storage_rocksdb.cc:43-45`、iter_next での skip :808-)。

### 3.3 誤同期を防ぐガード(server 側、`op_repl_sync_wal.cc:119-176`)

| ガード | 根拠 | 動作 |
|---|---|---|
| storage が RocksDB でない | :122-125 | `not_supported` → full dump |
| **master_id 不一致**(別系統の lineage = split-brain / backup 復元) | :133-146 | `master_id_mismatch` → full dump + token 採用 |
| **slave の LSN が master より先**(slave の方が新しい = 別 master 由来) | :148-160 | `lsn_ahead` → full dump でリセット |
| **要求 LSN が WAL からパージ済み** | :166-170 | `lsn_purged` → full dump で追いつく |
| WriteBatch がサイズ上限(16MB default)超過 | :203-209 | 中断 → full dump(チャンク分割は WriteBatch の原子性を壊すため行わない設計) |

**全エラーが full dump 行きなので、WAL sync の失敗がデータ破壊に至る経路はない**(handler 側の分類: `handler_dump_replication.cc:155-175`)。

### 3.4 障害時の自衛と事後清掃

- **self-demote**: resync が連続 `rocksdb-resync-failure-threshold`(default 3)回失敗すると自ノードを `state_down` に落とす(`handler_dump_replication.cc:249-275` 付近)。**RocksDB ディレクトリは触らないので、修復後に up し直せばデータは残っている**
- **orphan scan → purge**(2フェーズ、token 保護): failover / repartition 後に自パーティション外のキーを掃除する。scan(read-only)が topology version 付き token(TTL 300s)を発行し、purge は token 一致時のみ削除(`op_orphan_scan.cc`, `op_orphan_purge.cc`, token 管理 `storage_rocksdb.cc:1006-1047`)
- ⚠**設計上の注意**: full dump は key resolver で per-key にパーティションを絞る(`handler_dump_replication.cc:200-206`)が、**WAL sync は master の全書き込みをそのまま流す**(per-key フィルタなし)。master に orphan が残っている間はそれも slave にコピーされる。orphan_scan/purge での事後清掃が前提になっている点をレビューで合意しておくべき

### 3.5 【修正済み】確認されたバグ 2件(コミット `f68671c` で修正)

**F-1: `iter_begin()` の rdlock リーク**(`storage_rocksdb.cc:777-800`)

```cpp
int storage_rocksdb::iter_begin() {
	pthread_rwlock_rdlock(&this->_mutex_wholelock);   // :780
	if (this->_iter_snapshot) {
		log_warning("iteration already in progress", 0);
		return -1;                                     // :784 ← unlock せず return
	}
	...
```

unlock は `iter_end()`(:848)のみ。iteration 中に再度 `iter_begin()` が呼ばれると rdlock が永久リークし、以後 wholelock の wrlock を取ろうとするパスが永久に待たされる。→ **修正済み**: エラーパスに unlock を追加(`f68671c`)。

**F-2: `truncate()` が wholelock を取らない**(`storage_rocksdb.cc:735-775`)

`truncate()` は iterator で全キーをスキャンして 1 件ずつ `Delete` するが、`get()/set()/remove()/incr()` が取っている `_mutex_wholelock` を一切取らない。並行 `set` と競合すると、ヘッダキャッシュのクリア(:770)と並行書き込みのキャッシュ更新が交錯し、削除済みキーのバージョン整合が壊れうる。→ **修正済み**: `storage_tcb::truncate` と同じ規約(wholelock wrlock + 全 slot lock、`behavior_skip_lock` 尊重)で排他を追加(`f68671c`)。

### 3.6 レビュー時の追加確認事項(⚠要確認)

- ~~`get_master_id()` の並行アクセスガードなし~~ → **修正済み**(`f68671c`): 専用 rwlock を追加し、参照返しから値返しに変更
- `count()` は全キースキャン O(n)(`storage_rocksdb.cc:853-865`)。stats 系から高頻度に呼ばれるなら性能問題
- ワイヤプロトコルのテストは API レベルのみ(`test/lib/test_storage_rocksdb.cc`、WAL roundtrip / purge 検知 / incr clamp あり)。**LSN/BATCH フレーミングの不正入力・2プロセス E2E は #140 側の E2E(G1/G2)頼み**
- 耐久性のデフォルト: `rocksdb-sync-writes = false`(fsync なし、`ini_option.h:107` 付近)、WAL 保持 24h / 10GB。**レプリケーションで耐久性を担保する前提**のため、単一レプリカ運用では電源断で直近書き込みが失われうる — 運用ドキュメントに明記されているか確認

---

## 4. PR #140: Flare Operator(重点: master 一意性とデータ保全)

### 4.1 Reconcile FSM

reconcile は 12 状態の FSM(`StateMachine/K8sReconciler.lean:354-506`)を 5 秒 tick で回す:

```
Init → AfterFetchCRD → AfterListPods → AfterDetectDead ─┬→ AfterHandleFailover
                                                        └→ EmergencyPaused (terminal)
→ AfterAssignRoles → AfterUpdateConfigMap → AfterHandleReplication
→ AfterBroadcastTopology → AfterPatchService → Done (terminal)
```

各ステップで measure(12→0)が厳密に減少するため停止が保証される(定理 `flareReconcileStep_decreases_measure`)。エラーは `Error` terminal に落ち、次 tick で Init から再開(冪等)。

### 4.2 master 一意性(「masterがつねに一台」)の担保構造

**3層の防御**:

1. **割当ロジック**: `autoAssign`(`StateMachine/Reconciler.lean:122-155`)は `findPartitionNeedingMaster` が返す「**master 不在のパーティション**」にのみ master を割り当てる。この関数の仕様は Lean の定理として証明済み:

```lean
-- StateMachine/Reconciler.lean:79-83 (sorry なし、機械検証済み)
theorem findPartitionNeedingMaster_spec (state : FlareClusterState) (n pIdx : Nat) :
    findPartitionNeedingMaster state n = some pIdx →
    hasMasterForPartition state pIdx = false
```

   さらに系 `findPartitionNeedingMaster_noMaster`(:87-100)で「返されたパーティションに master ロールのノードは 1 つも存在しない」ことまで証明されている。

2. **単一 writer**: operator は K8s **Lease によるリーダー選出**で常に 1 インスタンスのみが reconcile する(`Main.lean:851-1021`、follower は passive)。FSM 自体もシングルスレッド逐次実行

3. **手動変異の拒否**: NodeRemove 等の外部変異はエラーとして拒否(`Reconciler.lean:240-243`)。トポロジーは operator が唯一の権威

**split-brain になりうる残余リスク**: K8s Lease の実装が二重リーダーを許した場合のみ(§4.6)。また、operator 視点の一意性であり、flared 側が古い topology broadcast を後着で適用しないか(version 逆転の扱い)は flared 実装の確認が必要(⚠要確認)。

### 4.3 フェイルオーバーとデータ保全(commit 4da9278 の核心)

**修正前の問題**: master pod が死ぬと demote まではするが、slave の昇格をしないため、StatefulSet が**同名で再作成した空 pod** が Proxy として登録され master スロットを取り、**パーティションのデータが静かに全損**していた。

**修正後**: dead master の demote と同一 tick で、**同一パーティションの生きている slave(= レプリカデータを保持したままの別 pod)を Master/Active に昇格**する:

```lean
-- StateMachine/K8sReconciler.lean:213-238 (handleFailoverWithPromotionSingleKey, 抜粋)
let demoted : FlareNode :=
  { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1 }
let s := s.addNode key demoted
if node.role == FlareRole.Master then
  ...
  match part.slaves.head? with
  | none => s  -- no slave to promote; slot stays empty until a node registers
  | some slaveKey =>
      let promoted := { slaveNode with role := FlareRole.Master,
                                       state := FlareState.Active, balance := 100 }
      let newPart := { part with master := some slaveKey, slaves := part.slaves.tail }
      (s.addNode slaveKey promoted).setPartition partIdx.toNat newPart
```

- 再作成された旧 master pod は Slave として登録され、新 master から再構築(Prepare → 完了後 Active)
- **slave がいない場合はスロットを空のまま残す**(:229)— 空ノードを master にするより安全側
- 回帰検知: `E2E/Tests/DataSurvivalFailover.lean` が「100 キー書き込み → master を強制 kill → **新 master から全キーを値まで完全一致で読み戻す**」を per-key で assert する(欠損・不一致は即 `.fail`、`.skip` なし)

### 4.4 状態管理の正しさ(commit cc74035 / 90e478d)

- **`mergeClusterState`**(`Main.lean:520-536`): FSM の計算結果を live 状態に**上書きではなく merge** する。flared からの TCP `node state ready` で起きた Prepare→Active 遷移を、並行して走った reconcile が Prepare に巻き戻さないためのガード。role 一致 かつ current=Active かつ 計算結果=Prepare のときのみ Active を保持
- **operator 再起動**: nodeMap は ConfigMap に serialize され(`K8sReconciler.lean:443`)、再起動時に reload して partitionMap を再構築(`Main.lean:914-922`)。failover 途中で死んでも次の reconcile が dead 検出からやり直すため冪等
- **kubectl デッドロック修正**(`Kubectl.lean:39-58`): 旧実装は stdin パイプで `kubectl apply -f -` に流し込み、EOF を送らず双方ブロック → **reconcile ループ全体が停止**する重大バグだった。新実装は一意な temp file + argv 直接実行(shell を経由しないため injection もない)

### 4.5 本番向け防御機構(各1行)

| 機構 | 内容 | 根拠 |
|---|---|---|
| dead 検出の対象限定 | Proxy/Down/**Prepare** を除外(大容量再構築中の誤殺を防ぐ)。Active な Master/Slave のみ対象 | `Main.lean:91-124`, `K8sReconciler.lean:248-259` |
| 起動 grace period | 起動後 120s(24 tick)は dead 検出をスキップ(RocksDB の起動が遅いケース) | `Main.lean:955-969` |
| circuit breaker | dead が閾値(default 50%)超で `EmergencyPaused` に遷移し自動 failover を停止(AZ 障害での連鎖demote防止) | `K8sReconciler.lean:120-157` |
| proxy throttling | 再構築はパーティションあたり 1 ノードずつ(同期ストーム防止) | `Reconciler.lean:30-42` |
| K8s API retry | exponential backoff + jitter(100ms→30s、5回) | `K8s/Retry.lean:59-138` |
| 可観測性 | Prometheus(:9090)/ health probe(:8080) | `Metrics/Prometheus.lean`, `Health/HealthCheck.lean` |

### 4.6 残余リスク(レビューで議論すべき点)

**R-1【最優先】bootstrap 時の二重 master 競合の疑い**: TCP サーバーと FSM ループは同じ `stateRef` を書き換えるが、`commitClusterState` は **version CAS なしで常に merge をコミット**する(`Main.lean:538-548`、コメントに「Always commits」と明記)。次のインターリーブが成立しうる:

1. FSM が snapshot を取る(P0 master 不在)
2. その間に TCP `node add` で pod-X が登録 → P0 特例(`Reconciler.lean:195-215`)により live ref 上で pod-X = Master P0 (Active) に即時割当
3. FSM は古い snapshot から別の proxy pod-Y = Master P0 を `ucs` に割当
4. commit: `mergeClusterState` は `ucs` の pod-Y をそのまま採用し、snapshot 後に登録された pod-X は「current-only」としてそのまま持ち越す(`Main.lean:531-535`)→ **P0 に master が2つ**

窓は狭い(FSM 1 サイクル中の P0 未割当期間)が、pod が一斉に登録される bootstrap はまさにこの条件。発生後に重複 master を demote する修復ロジックは存在しなかった。

→ **修正済み**(`141d725`): `mergeClusterState` を pure 層(`K8sReconciler.lean`)へ移設し、merge 後に `demoteDuplicateMasters` で重複 master を修復(FSM 側の割当が勝ち、重複は未割当 Proxy に demote → 次の tick で再割当)。partitionMap も merge 後の nodeMap から再構築。このインターリーブそのものを符号化した回帰定理 `r1_merge_repairs_double_master` / `r1_merge_keeps_fsm_master` / `r1_merge_demotes_tcp_duplicate` が `VerifiedSafety.lean` で機械検証済み。

**R-2【修正済み `69d49ac`】ゾンビ master 復活によるデータ喪失**: flared プロセスだけが再起動して pod が生存リストから消えない場合、dead 検出→failover は一度も走らない。ところが `node add` 再登録は Master エントリを Proxy で置き換えるため、次の reconcile の `autoAssign` が「master 不在」のパーティションを**空の proxy(典型的にはゾンビ自身)に Master/Active として明け渡していた**。データを持つ slave は slave のまま — サイレントな全損。モデルで再現確認済み(修正前 scenario4)。→ `autoAssign` に Active slave 優先昇格ガードを追加し、`scenario4_zombie_not_master` 等4定理で固定(ゾンビは Slave/Prepare で復帰し、昇格するのはデータ保持 replica)。

2. **Lease 二重リーダー**: 全安全性が「operator は常に1つ」に依存。Lease の renew 失敗→旧リーダーが気づかず書き続ける時間窓がないか、Lease 実装(`Main.lean:880-989`)を重点確認
3. **Prepare 固着**: 再構築が失敗しても pod が生きていると Prepare のまま永久に残る(dead 検出から除外されているため)。watchdog がない — follow-up issue 推奨
4. **kubectl subprocess 方式**: API client でなく kubectl を叩く。エラー分類・レート・可搬性の観点は許容範囲か
5. **flared 側の古い topology 受信**: version 逆転 broadcast を flared が無視するかは flared 実装依存(⚠要確認)

---

## 5. 形式検証の実態: **実装と証明の不一致(重要)**

結論から言うと、**当初の「形式検証」はこの PR の安全性の根拠にならなかった**。証明自体は Lean kernel を通っているが、証明対象のモデルが本番実装と乖離しており、看板となる定理はほぼ自明な命題に落ちていた。以下すべて実コードで確認済み。

> **修正済み**(`968e423`): §5.1〜5.2 の問題は解消。モデルの reconcile は本番の `assignProxiesPure` を、failover は本番の `detectDeadNodesPure` + `handleFailoverWithPromotion` を直接呼ぶようになり、以下が新たに機械検証された(すべて `decide`、sorry なし):
> - **非自明性**: `scenario2_p0_has_master` / `scenario2_p1_has_master` — 初期化完了時に**両パーティションに master がちょうど1つ**存在する(reconcile が no-op に退化すると**コンパイルが落ちる**カナリア)
> - **failover 安全性**: `scenario3_verified` / `scenario3_p0_still_has_master` / `scenario3_dead_node_not_master` — P0 master の pod 死亡後も不変条件が保持され、master スロットは死んだ pod とは**別の生きた pod**(= データを保持する replica)で埋め直される
> - **R-1 merge 修復**: §4.6 参照
>
> 未解決のまま残るギャップ(§5.3 の一般帰納証明 `sorry`、逐次モデル(真の並行性は未検証)、IO 層)はドキュメントに明記した。以下の 5.1〜5.2 は**修正前の状態の記録**としてレビューの参考のため残す。

### 5.1 モデルの reconcile は no-op(最大の問題)

証明の舞台であるモデル `stepGlobal` の `.OperatorReconcile` は、本番の 12 状態 FSM ではなく legacy のイベントハンドラを **`.Ping` イベントで**呼んでいる:

```lean
-- StateMachine/GlobalModel.lean:161-164
| .OperatorReconcile =>
    let (newOpState, _) := reconcileStep g.operatorState g.crdSpec .Ping
```

```lean
-- StateMachine/Reconciler.lean:166-168
match event with
| .Ping =>
  (state, .OK)        -- 状態を一切変更しない
```

つまり**モデル内の「reconcile」は状態を変えない no-op**。役割割当(Proxy→Master/Slave)はモデル内では `NodeAdd` の P0 特例(`Reconciler.lean:195-215`)でしか起きない。

### 5.2 その帰結: `scenario2_verified` はほぼ自明

看板定理 `scenario2_verified`(`VerifiedSafety.lean:77`)が検証する `scenario2_fullInit`(`Simulation.lean:35-65`)の 17 ステップを追うと:

- Step 1-4 (`NodeAdd`×4): node-0 のみ P0 特例で Master P0 に。node-1〜3 は Proxy
- Step 5 (`.OperatorReconcile`): コメントは「assigns Proxies to roles」だが、上記の通り **no-op**
- Step 6-17: broadcast / reconstruction / ready 処理。新たな master 割当なし

したがってトレース終了時、master は **P0 の 1 つだけ。コメントにある「node-2 = P1 Master」(`Simulation.lean:56`)はモデル内では実現していない**。「at most one master per partition」は master を 1 つしか作らないトレース上では自明に成立する。`FORMAL_VERIFICATION.md` の「完全な本番デプロイトレースを検証、このパスにバグは隠れられない」という主張は実態と乖離している。

### 5.3 証明されていないもの(本番で実際に動くコード)

| 本番コード | 役割 | 証明 |
|---|---|---|
| `flareReconcileCore`(`K8sReconciler.lean:354-506`) | 本番の 12 状態 FSM(役割割当・failover を含む) | **なし**(measure 減少=停止性のみ) |
| `handleFailoverWithPromotion`(`K8sReconciler.lean:213-246`) | master failover / slave 昇格 — **最重要ロジック** | 当初**なし**(`GlobalStep` にノード死亡ステップが存在しなかった)→ `968e423` で `NodeDie` ステップを追加し、シナリオレベルの証明(`scenario3_*`)を新設 |
| `mergeClusterState` / `commitClusterState` | TCP と FSM の並行書き込みの merge | 当初**なし** → `141d725` で pure 層へ移設し、R-1 インターリーブの回帰定理を追加。ただし**インターリーブそのもの(真の並行性)は依然モデル外** |
| 一般帰納安全性 `stepPreservesAtMostOneMaster` | 任意ステップでの不変条件保持 | **`sorry`**(`Safety.lean:73`、他 `Safety.lean:134`、`SafetyProofs.lean` にも複数) |

### 5.4 意味のある証明(実装と接続しているもの)

- `findPartitionNeedingMaster_spec` / `_noMaster`(`Reconciler.lean:65-100`): 「master 不在のパーティションしか返さない」— **本番の `autoAssign` が実際に使う関数**の仕様証明であり、これは本物。ただし局所的な補題であり、割当後の状態が不変条件を満たすことの証明ではない
- `Liveness.lean` の停止性 / ESR: FSM の measure 構造については有効。ただし 9 個の仮定(kubectl 成功、単一 operator 等、`Liveness.lean:89-116`)の下

### 5.5 レビューとしての扱い

- **この PR の安全性評価は「実装コード + E2E テスト」のみで行うべき**。形式検証は現状 aspirational(将来の枠組み)であり、判断材料に含めない
- `FORMAL_VERIFICATION.md` と `VerifiedSafety.lean` 内の「impossible for bugs to hide」等の記述は**実態に合わせた修正を要求すべき**(モデルの reconcile を実際の割当ロジックに接続するか、主張をトーンダウンするか)
- 修正案として最小限意味を持たせるなら: `stepGlobal .OperatorReconcile` を `assignProxiesPure` 相当に差し替えて scenario2 を再検証し、ノード死亡ステップをモデルに追加すること

---

## 6. E2E テスト

kind 上で実 StatefulSet + operator を動かす 18 スイート(~96 テスト)。CI は `.github/workflows/e2e-tests.yaml`(120分 timeout、テスト本体 90分)。

**重点スイート**:

| スイート | 検証内容 |
|---|---|
| **data-survival-failover** | §4.3 の通り。**データ全損バグの回帰を fail で検知する唯一のテスト**。`.skip` を許さない設計が良い |
| **terminating-pod-handling** | grace-period 30s の Terminating master を「死」と判定し、猶予期間の満了前に slave 昇格できるか(redis-operator #1544 と同型の問題) |
| **failover-during-replication** | Blue/Green migration の Dumping 中に master kill → failover 後も replication 状態が復旧可能か(Vitess #8909 と同型) |
| partition-reduction | パーティション削減(2→1)を**ブロック**することの確認(削減はデータ喪失リスクのため拒否する設計) |
| G1/G2/G5/G7/G10-G12 | RocksDB 連携: WAL 増分同期、purge 時 fallback、self-demote、orphan purge、CRD→ConfigMap の設定伝播 |

**SKIP 7件の内訳**(`docs/e2e-test-issues.md`)— いずれも既知のインフラ/flared 側制限で、operator ロジックの不具合ではない:

- flared の `ini_option::reload()` が SIGHUP で `rocksdb-wal-sync-bwlimit` 等を再適用しない(flared 側の別修正が必要)
- E2E 環境が emptyDir(PVC なし)のため、pod 再起動を跨ぐ LSN 永続や orphan 発生を再現できない

⚠ **PVC なしの E2E では「ディスク上のデータが pod 再起動を生き残る」経路は未検証**。data-survival は「別 pod のレプリカ昇格」で担保している点に注意。

---

## 7. レビューワー向けチェックリスト

裏取り用の一次ソース一覧。**全項目の現状を反映済み(2026-07-13)**。✅ = 修正/検証完了、⏳ = 対応中、□ = 未対応(合意事項/優先度低)。

| 状態 | 確認事項 | 解決内容 / 場所 |
|---|---|---|
| ✅ | `iter_begin` の rdlock リーク(F-1) | `f68671c` で unlock 追加。並行性テストも `dda75dd` で追加 |
| ✅ | `truncate` の排他なし(F-2) | `f68671c` で tcb 同等のロック規約に。truncate/set 競合テストで検証 |
| ✅ | `_master_id` の並行アクセス | `f68671c` で専用 rwlock + 値返しに変更 |
| ✅ | 昇格ロジック(空スロット維持・**live pod のみ昇格**) | `4da9278` + ゾンビガード `69d49ac` + **liveness ガード `aa9c055`**。scenario3/4/5 の計10定理で機械検証(dead 不昇格・ghost 不昇格・データ保持 replica 優先) |
| ✅ | LSN+データの原子的適用 | レビューで検証済み(`apply_batch_with_lsn`、単一 WriteBatch)。WAL roundtrip 単体テストあり |
| ✅ | 二重 master 競合(R-1) | `141d725` 修復 + `3464ee9` で**任意入力の一般定理**(`mergeClusterState_atMostOneMaster`、sorry なし) |
| ✅ | 形式検証の主張と実装の乖離 | `968e423` でモデルを本番関数に接続。§5 追記参照 |
| ✅ | WAL sync 全エラーの full dump フォールバック | コードレビューで検証 + `31daf5c` の WAL-first 再構築も同じ非破壊フォールバック設計。G1/G2 E2E が実経路を execute |
| ✅ | merge の Prepare→Active 非巻き戻し / 登録消失なし / 死者復活なし | pure 層へ移設(`141d725`)+ 一般定理3本(`9d736d3`)。Prepare→Active 保存そのものの専用定理は未追加(低リスク: 条件は単一分岐) |
| ✅ | Lease 二重リーダー窓 | `9a75a10` でレビュー完了 + broadcast 直前フェンス追加。残余窓(送信中1回分)は文書化済み |
| ⏳ | 一般安全性定理の `sorry`(`Safety.lean:73,134`) | 未解消(唯一の残存項目)。commit 境界の一般定理でリスクの大半をカバー。分解ロードマップあり |
| □ | `count()` の O(n) スキャン | 未対応(性能課題、機能影響なし)。stats 呼び出し頻度の実測後に判断 |
| □ | WAL sync の per-key partition フィルタなし(orphan purge 前提の設計合意) | 設計合意事項として残置。orphan purge の E2E は PVC 化(`b0d62f1`)で実アサート化済み |
| □ | flared の version 逆転 broadcast 耐性 | 未調査(flared 側)。operator は単一 writer + version 単調のため実害シナリオは限定的 |

**参考ドキュメント(PR 内)**: `flare_operator/docs/FORMAL_VERIFICATION.md`(`968e423` 以降は実態と一致するよう修正済み — 証明済み/未証明の区分が明記されている)、`docs/BACKUP_RESTORE.md`(バックアップ/リストア手順)、`flare_operator/docs/ARCHITECTURE.md`、`docs/e2e-test-issues.md`、`ROCKSDB_REPLICATION.md`

---

## 8. 証明と実装の乖離: 現状(2026-07-13)

**是正済み**:
- モデルの全ステップが**本番と同一の関数を呼ぶ**: `NodeAdd`→`reconcileStep`/`autoAssign`(TCP fast path の `[nodeKey]` 制限も同一)、`OperatorReconcile`→`assignProxiesPure`(livePodKeys 配線も同一)、`NodeDie`→`detectDeadNodesPure`+`handleFailoverWithPromotion`、commit 境界→`mergeClusterState`
- **非自明性カナリア**: 初期化で両パーティションに master が立つこと・Ready 連鎖が完走することを定理化 — モデルが空回りに退化すると**コンパイルが落ちる**
- **一般定理**(シナリオ非依存・任意入力): master 高々1(commit 境界)・登録消失なし・死者復活なし
- 危険シナリオ(failover / ゾンビ / ゴースト)はすべて「実装が変われば証明が落ちる」形で固定

**残る乖離(正直な列挙)**:
1. `stepPreservesAtMostOneMaster` の `sorry` — 任意ステップ列への帰納証明は未完(唯一の証明負債)
2. **モデルは逐次** — TCP サーバと FSM の実インターリーブは対象外(R-1 は merge 関数の性質として証明したが、インターリーブ生成自体はモデル外)
3. **IO 層は対象外** — kubectl・TCP wire・ConfigMap 永続化はモデルにない
4. **C++ flared の複製挙動はモデル外** — `FlaredNode.lean` は role shift の骨格のみ。今回追加した WAL-first 再構築・LSN 種付け(`31daf5c` `2b4b028`)は C++ 側にしか存在せず、これらの正しさは E2E とコードレビューが担保(モデル化は future work)

要約: **「証明が実装と別物」という当初の問題は解消**し、pure 層(割当・failover・merge)は共有コードとして機械検証されている。残るのは「一般帰納」「並行性」「IO/C++ 層」という、当初から明記していた3つの構造的限界。
