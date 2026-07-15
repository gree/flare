# flare-operator レビュー概説 — flare 内部を知らないレビューワー向け

対象 PR: [#140](https://github.com/gree/flare/pull/140)(operator 本体、#142 の RocksDB 変更を包含)。
これは判断のための資料です。flare のコード詳細に踏み込んだ調査メモは
[review-pr140-pr142.md](review-pr140-pr142.md) にあり、本書の各行はそこへの入口です。

## 30秒サマリ

flare は「パーティション分割 + master/slave 複製」の分散 KVS で、この PR は
その司令塔(どのノードが master か、いつ failover するか、いつデータを
コピー/削除するか、を決める部分)を Kubernetes operator として書き直すもの。
司令塔の誤判断はそのままデータ喪失になる。本 PR の主張は:
**危険な判断はすべて純粋関数に分離され、その関数そのものが機械検証されており、
同じ危険シナリオを実クラスタ E2E でも毎回演習している** — この三点が揃って
いるかを確認するのがレビューの本筋である。

## 守りたかったもの4つ — 何を証明し、証明できないものは何でテストしたか

この開発が避けようとしたのは結局4つである。各項目について「証明」
「証明できない部分のテスト」「どちらも届かない残余」を分けて書く。
後続の P1〜P5 対応表はこの4目標の実装明細である。

### 1. スプリットブレイン(所有権の分裂)

- **証明した**: master は各パーティション高々1 — 任意の状態・任意の操作列で
  ([`stepGlobal_preserves_atMostOne`](../flare_operator/FlareOperator/StateMachine/GeneralSafety.lean#L511)、一般帰納)。並行書き込みの合流点も任意
  入力で([`mergeClusterState_atMostOneMaster`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L492))。古い計算による幽霊 master の
  蘇生も封印([`ghost_not_resurrected`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L308))。過半死で誤って一斉昇格しないことも
  (breaker 定理)
- **証明できずテストした**: operator の権威 view が flared 側の view に
  正しく届くこと(broadcast の配線)— failover 系 E2E 全部 + operator-restart
  の構成同一性で担保。**全開発期間の全 CI で二重 master 観測ゼロ**
- **残余**: 3AZ 構成で1AZ だけが隔離された場合、隔離側の旧 master を遠隔
  降格できない(ウォークスルー2b)。fencing/quorum なしの原理的限界として明記

### 2. ノード間のデータのバージョン不一致(複製の食い違い)

- **証明した**: この目標は実体が C++ 複製層にあるため証明は薄い、と正直に
  言うのが正確。モデル側で証明したのは境界部分のみ — merge が複製の前提情報を
  壊さないこと(登録消失なし [`mergeClusterState_preserves_keys`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L540)、Down 保存、
  Prepare→Active の非巻き戻し)
- **証明できずテストした**: 食い違いを防ぐ実機構は3つで、すべて C++ 単体
  テスト + E2E 担保: ① **lineage token**(`master_id` 不一致の WAL を拒否 —
  誤系統のデータ混入を遮断。単体テストで拒否経路を検証)、② **LSN の原子適用**
  (データと複製カーソルを単一 WriteBatch で書く — 再生の重複でカウンタ類が
  ドリフトしない)、③ **削除の伝播**(WAL 再生は削除を運ぶ = G1 E2E /
  WAL 切れの長期離脱はゲート付き truncate+full dump = G2 E2E — 「消した
  データが復帰ノードで蘇る」stale read の遮断)。加えてパーティション外キーの
  掃除(orphan scan/purge E2E)
- **残余**: 分断中に少数派側へ書かれたデータは rejoin 時に破棄される
  (バージョン分岐を「破棄」で解消する非クォーラム系の設計。明記済み)

### 3. システムの安定性(制御ループが暴れない・収束する)

- **証明した**: reconcile FSM は必ず停止する(measure 厳減)。過半死では
  トリップし([`circuitBreakerDecision_trips`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L143))、閾値未満では絶対にトリップ
  せず([`_no_trip`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L154))、**トリップ中は状態変更も K8s 要求も一切発生しない**
  ([`emergencyPaused_inert`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L864) — 保護機構自身がチャーン源にならない)。収束
  (ESR)は9つの公平性仮定下でのみ証明 — safety より弱い保証であることを明記
- **証明できずテストした**: 実時間での収束 — 全 E2E が時間上限つきで
  「収束したこと」まで assert(failover ≤120s 等)。再起動しても構成が
  揺れないこと(operator-restart の2点サンプル)。再構築の暴走防止
  (パーティションあたり1本の throttling、scale 系 E2E)。設定伝播が
  発振しないこと(検証付き再 SIGHUP、G10–G12)
- **残余**: 実データ規模での再構築時間と猶予期間の妥当性(ステージング項目)

### 4. データの安定性(コミット済みデータが失われない・勝手に蘇らない)

- **証明した**: **Active な master は必ずデータを保持**([`activeMasterHoldsData`](../flare_operator/FlareOperator/StateMachine/GlobalModel.lean#L317)
  が failover/ゾンビ/幽霊の全シナリオで成立)。昇格対象は常にデータを持つ
  生きた replica(scenario3/4/5 定理)。復旧処理自身による喪失の禁止 —
  truncate の三重ゲートを仕様化し、**ゲートを外す変更はモデルのコンパイルが
  通らない**([`ungated_truncate_destroys_last_copy`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L237))
- **証明できずテストした**: ディスク上の実データの生存 — per-key 完全一致の
  読み戻し(data-survival)、パーティション全損からの PVC 復旧
  (pvc-data-survival)、論理破壊からの checkpoint 復元(backup-restore)。
  「蘇らない」の側は削除伝播 E2E(G1/G2)が担保
- **残余**: 論理破壊時の RPO はバックアップ間隔。分断少数派の書き込み(上記2)

## システムが保持する状態の全景

障害の議論は「どの状態が失われたか」の議論なので、先に全状態を列挙する。
レビュー観点は2つ: **各状態に書き手が一人か**(二重 writer は split-brain の芽)、
**失われたときの復旧経路があるか**。

| 状態 | 実体 | 書き手(唯一か) | 寿命 | 失うと / 復旧経路 |
|---|---|---|---|---|
| 望ましい構成(partitions, replicas, rocksdb 設定, breaker 閾値) | FlareCluster CRD | 利用者のみ | etcd | 利用者が再作成 |
| **クラスタの権威状態**(各ノードの role / state / partition / balance / regEpoch) | operator メモリ内 `FlareClusterState`(nodeMap + 派生 partitionMap + version) | **二重**: TCP サーバ(登録・Ready)と FSM(割当・failover)が同じ ref を書く — これが唯一の意図的な二重 writer であり、**合流点 merge が P1/P4 で証明されている理由そのもの** | operator プロセス | ConfigMap から復元(次行) |
| 権威状態のスナップショット | ConfigMap `{cr}-node-map` | operator のみ | クラスタ | 消えても再登録+再割当で再構築可能(ユーザーデータは無事)。operator-restart E2E が復元の同一性を検証 |
| flared 配布設定 | ConfigMap `{cr}-config`(extra.conf) | operator のみ(初期値は Helm pre-install hook) | クラスタ | operator が次 tick で再生成 |
| リーダーシップ | K8s Lease | 現リーダーのみ(JSON Patch の CAS) | クラスタ | 期限切れ→他レプリカが取得。残余窓は broadcast 前の lease fence で緩和 |
| flared プロセス内の自己認識(自分の role、ローカル node map、再構築進行) | flared メモリ | flared 自身(operator の broadcast を受けて) | プロセス | 再起動で消える → 再登録(regEpoch が新旧を判別)。**broadcast の意味論が C++ とモデルで食い違った箇所が実バグ4件目**(Active-shift) |
| **ユーザーデータ** | RocksDB 本体(PVC 上) | flared のみ(書込・複製・再構築・truncate) | **PVC(pod を超える)** | レプリカから再構築 / 全レプリカ喪失は checkpoint から復元(backup-restore E2E)。truncate の三重ゲート(P3)が「復旧処理自身による喪失」を防ぐ |
| 複製カーソルと系統 | 予約キー `__flare_repl_last_lsn` / `__flare_repl_master_id`(RocksDB 内) | flared の複製機構のみ | PVC | 消えても full dump に退化するだけ(安全側)。lineage 不一致は WAL 適用を拒否 → 誤系統のデータ混入を防ぐ |
| バックアップ | `backups/` checkpoint(PVC)+ S3(tier-2) | flared `backup` op / CronJob | PVC / S3 | 最後の砦。鮮度は `rocksdb_last_backup_epoch` で監視 |
| pod の存在・Ready | K8s(StatefulSet) | kubelet | — | dead 検出の入力。**「pod 存在 ≠ プロセス健全」のずれ**がゾンビ/幽霊シナリオの根であり、P2/P4 が守る |
| FSM の途中状態・猶予カウンタ | operator メモリ(tick ごとに Init から再構築) | FSM のみ | 1 tick | **意図的に非永続** — 毎 tick 白紙から再評価するから breaker が自動復帰できる(P5) |

モデル(`GlobalModel.GlobalState`)はこのうち権威状態(operatorState)・flared 自己認識
(nodeStates、データ保持は `holdsData` に抽象化)・両者間のメッセージ(queues)を
写像している。**表の「書き手が二重」の1箇所と「pod 存在≠健全」の1箇所が、
発見された operator 側バグ全件の発生源である** — 状態表の異常箇所と
バグの分布が一致していること自体が、この整理の妥当性の傍証になっている。

## 想定した障害モデル(何が起きると仮定したか)

設計・検証が前提にした障害ケースの全列挙。「検証」列が空欄のケースは存在しない
(空欄を作らないことがこの表の目的である)。

| 障害ケース | 対応機構 | 検証 |
|---|---|---|
| flared プロセスのみ死亡(pod は残存、即再起動 = ゾンビ) | 再登録時、データを持つ Active slave を優先昇格 | scenario4 定理群(モデルで再現→修正→封印) |
| pod 削除 → 同名再作成(単発) | dead 検出 → 生きた slave の昇格 | scenario3 定理 + failover / data-survival E2E |
| master+slave 同時喪失(パーティション全損) | PVC 永続化 + 幽霊エントリの昇格禁止 + 登録エポック merge | scenario5 定理 + pvc-data-survival E2E |
| pod が Terminating で固着(grace period 中) | pod list ベースの検出(Terminating = 不在扱い) | terminating-pod-handling E2E |
| AZ 級の過半数同時死 | circuit breaker(トリップ→不活性→自動再開) | breaker 定理3本 + circuit-breaker E2E |
| operator 自身の死・再起動 | 状態の ConfigMap 永続化 + Lease リーダー選出 + broadcast 直前の lease fence | operator-restart E2E(構成同一性 + 再起動後 failover) |
| 論理破壊(誤 flush_all・誤削除 — 複製では守れない) | RocksDB checkpoint バックアップ + RESTORE フック | backup-restore E2E(全損→全キー復元) |
| 長期離脱ノードの復帰(離脱中の削除の伝播) | WAL 再生(短期)/ ゲート付き truncate+full dump(長期) | P3 定理(ゲートの仕様化)+ G1/G2 E2E |
| 設定変更の伝播失敗(kubelet 遅延と SIGHUP の競合) | 伝播確認付き再 SIGHUP(tick 分割・非ブロッキング) | G10–G12 E2E |
| 再構築中のノードの誤殺(大容量データで数時間 Prepare) | Prepare を dead 検出から除外 + 固着 watchdog(警報のみ) | E2E(暗黙)+ 運用アラート `FlarePrepareStuck` |
| **選択的ネットワーク断(pod 生存・TCP のみ不通)** | tick ごと再送 + lease fence(**緩和のみ**) | **未カバー** — 明示的な残余リスク。ステージング障害注入で検証すべき項目 |

最後の1行が「この表で唯一、検証列が弱いケース」であり、これを隠さないことが
本資料の信頼性の担保である。

## ウォークスルー: AZ 障害の2形態で何が起こるか

具体例で機構を追う。構成: 2 AZ(az-a / az-b)、2パーティション×2レプリカ。
zone 分散制約により配置は P0-master(a), P0-slave(b), P1-master(b), P1-slave(a)。
operator はレプリカ2(leader が a、standby が b)。breaker 閾値は既定 50%。

### 形態1: AZ 片側の崩壊(az-b が丸ごと死ぬ)

| 時刻 | 起きること |
|---|---|
| T+0 | az-b のノード群が停止。P0-slave / P1-master / operator-standby を喪失。**P0 は無傷で継続、P1 range への書き込みは失敗し始める** |
| T+40s〜数分 | K8s が az-b ノードを NotReady と判定し pod を退去。operator の pod list から az-b の pod が消える |
| 次の tick | dead 検出: 4 台中 2 台 = **50% ≥ 閾値 → circuit breaker がトリップ**。`CIRCUIT BREAKER TRIPPED` ログ + `FlareCircuitBreakerTripped` がページ(critical) |
| トリップ中 | **operator は何もしない**([`emergencyPaused_inert`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L864) 定理: 状態変更も K8s 要求もゼロ)。P1-slave(a) を昇格させないのは意図的 — 大規模障害の最中の一斉再割当は復旧を妨げる、が P5 の設計判断。P0 は provide し続ける |
| 復旧 A: az-b が帰ってくる | pod 再登録 → 死亡率が閾値未満に低下 → **breaker は自動解除**(毎 tick 白紙から再評価するため。operator 再起動は不要 — 旧ドキュメントの誤りは修正済み)→ 通常の failover が実行: P1-slave(a) が昇格(**データを持つ生きた replica** — P2 定理)、戻った az-b pod は slave として WAL/dump で追いつく |
| 復旧 B: az-b が恒久喪失 | 人間の判断(Runbook「circuit-breaker」節): StatefulSet を縮退させ生存率を閾値超にする、または閾値を下げる → failover 進行 → P1-slave(a) 昇格。全パーティションが az-a で提供再開 |

**この間ずっと成立している保証**: master は増えない(P1)、昇格するのは
データを持つ生きた replica だけ(P2/P3)、P1 range の書き込みは「静かな
破壊」ではなく**明示的な失敗**としてクライアントに返る。データは P0 が無傷、
P1 は az-a の slave と az-b の PVC の2箇所に残っており、**何も失われていない**。

### 形態2: AZ 間の通信途絶(両側とも生きているが、互いに見えない)

こちらが本質的に難しいケースで、さらに2つに分かれる:

**2a. pod 間だけ不通、K8s API へは両側から到達可能**(クラウドでは典型)
- az-b の kubelet は API に状態を報告し続ける → pod list は全員「存在」
  → **dead 検出は発火しない**。operator は az-b への broadcast 失敗を
  ログに残しつつ毎 tick 再送する(それ以上の事は**しない**)
- 挙動: 各 AZ は自分側のパーティション master へは読み書き可能、
  相手側 range への proxy 転送は失敗。**可用性は AZ ローカルに縮退するが、
  master は一意のままで分岐(split-brain)は起きない** — operator が
  再割当しないことが、この形態では正しさそのもの
- これが障害モデル表で唯一「緩和のみ」とした残余ケースの実体。
  安全側に倒れる(何もしない)ことは確認済みだが、能動的な検知・報知は
  ないため、発見はクライアントエラー率の監視に依存する

**2b. az-b が API からも隔離**(完全分断)
- K8s 視点では形態1と同一に進む(NotReady → 退去 → 50% → breaker)。
  **しかし az-b の flared は生きていて、az-b 内のクライアントに提供し続けている**
- 2 AZ 対称構成では breaker(50%)がここでも救いになる: operator は
  昇格しないので「両側に master」は生じない
- **正直な限界**: 3 AZ 構成で 1 AZ だけが隔離された場合(死亡率 33% < 50%)、
  operator は隔離側の master を死亡とみなし生存側で昇格する。隔離側の
  旧 master は(broadcast が届かないため)自分の降格を知らずに隔離内の
  クライアントへ提供を続け、**分断期間中は「双方が自分こそ master」の状態が
  生じうる**。flare にはクライアント側 fencing / quorum がないため、
  これは検知不能な「隔離 vs 死亡」の曖昧さに由来する原理的限界である
- その場合の収束: 分断解消後、隔離側ノードは再登録(regEpoch で新旧判定)
  → slave として再割当 → ゲート付き truncate + 再構築で新 master に同期。
  **分断中に隔離側へ書かれたデータはこのとき破棄される**(少数派書き込みの
  犠牲 — 非クォーラム系の標準的な代償であり、隠さず明記する)

**レビューワーへの要点**: 形態1は「設計どおりに守られる」ケース(P5 の存在
理由)、形態2a は「何もしないことが正しい」ケース、形態2b の 3AZ 亜種だけが
本システムの原理的限界であり、必要なら次の段階(クライアント fencing、
書き込みクォーラム)の投資判断材料になる。

## なぜこの5性質で十分と考えるか(十分性の論証)

十分性は定理ではなく論証なので、構造を明示する:

1. **KVS が守るべき契約は2つに還元される**: 各キー範囲の所有者(master)は
   常に一意である(→ P1)、かつ所有者は委ねられたデータを持っている(→ P3)。
   この2つが常に成り立つなら、クライアントから見た正しさ(書き込みの一意な
   行き先、読み出しの正しい応答)は flared のプロトコル実装の問題に還元される。
2. **P2・P4・P5 は「P1∧P3 を壊しうる遷移」の網羅である**: 所有権とデータを
   変えるコード経路は、割当(autoAssign)・failover(handleFailover*)・
   状態合流(mergeClusterState)・C++ の再構築、の4つしかない。前3者は
   P1/P2/P4/P5 の定理が遷移ごとに保護し、C++ 再構築は P3 のゲートが保護する。
3. **経路の網羅性は構文的に検査できる**: operator の nodeMap を書き換える
   関数は `addNode` の呼び出し元の全列挙で確認できる(grep 一発)。
   「証明されていない第5の経路」が紛れ込めば、CI の全定理再検証が
   その関数の変更に反応しない代わりに、この列挙が増える — レビューで
   見るべきはこの列挙の増減である。

**十分でないと自覚している部分と、そのカバー先**:

| 未証明領域 | なぜ証明しない/できないか | カバー |
|---|---|---|
| C++ flared の複製プロトコル実体(WAL 転送・dump の中身) | 別言語・別プロセス。形式化コストが便益を超える | 単体テスト(パーサ・並行性・チェックポイント)+ WAL 系 E2E(G1/G2)+ 意味論を定めるのはモデル側という規約(乖離が出たら C++ を直す — 実績1件) |
| IO 境界(証明済み関数に正しい引数を渡しているか) | 証明の対象は関数、呼び出しはシェル | E2E 22スイート + 失敗時診断フック。境界バグが出るたびに判断材料を証明層内に移す(登録エポックが実例) |
| liveness(いつか必ず収束) | 公平性など9仮定が必要で、safety と同格にはならない | E2E の全シナリオが「収束したこと」まで assert(時間上限つき) |
| 実環境スケール(再構築時間、猶予期間の妥当性、実 AZ 分散) | kind では原理的に再現不能 | **未カバー** — ステージング障害注入(運用ロードマップに明記) |


## 性質 → 実コード → 証明 → E2E の対応表

| # | 性質(平文) | 守っている実コード | 機械検証(定理) | 実クラスタ E2E |
|---|---|---|---|---|
| P1 | **master は各パーティション高々1** | 割当は「master 不在のパーティション」にのみ行う [`findPartitionNeedingMaster`](../flare_operator/FlareOperator/StateMachine/Reconciler.lean#L60-L61) / 並行書き込みの合流点で重複 master を修復する [`mergeClusterState`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L375)+[`demoteDuplicateMasters`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L315)(いずれも [`StateMachine/K8sReconciler.lean`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean), [`Reconciler.lean`](../flare_operator/FlareOperator/StateMachine/Reconciler.lean) — 本番がそのまま実行する関数) | **一般帰納**(任意の状態・任意のステップ列・無制限長): [`stepGlobal_preserves_atMostOne`](../flare_operator/FlareOperator/StateMachine/GeneralSafety.lean#L511) / [`stepMany_preserves_atMostOne`](../flare_operator/FlareOperator/StateMachine/GeneralSafety.lean#L520)([`GeneralSafety.lean`](../flare_operator/FlareOperator/StateMachine/GeneralSafety.lean))。合流点単体でも任意入力で [`mergeClusterState_atMostOneMaster`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L492) | failover / pvc-data-survival / circuit-breaker。**全開発期間・全 CI で二重 master の観測ゼロ** |
| P2 | **failover はデータを持つ「生きた」replica を昇格する**(空の再作成 pod や、pod が消えた幽霊エントリを master にしない) | [`handleFailoverWithPromotionSingleKey`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L241)(demote と同 tick で slave 昇格、role/partition の防御ガード付き)+ pod 生存リストで候補を絞る [`findActiveSlaveForPartition`](../flare_operator/FlareOperator/StateMachine/Reconciler.lean#L131) | failover: [`scenario3_dead_node_not_master`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L133)、ゾンビ: [`scenario4_zombie_not_master`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L167-L170)、幽霊: [`scenario5_ghost_not_promoted`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L197)(いずれも [`VerifiedSafety.lean`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean)、モデルは本番と同一関数を呼ぶ) | data-survival-failover(**100キーを値まで完全一致で読み戻す**。欠損は即 fail)/ pvc-data-survival(master+slave 同時死)/ terminating-pod-handling |
| P3 | **Active な master はデータを保持している**(「空 master」の禁止 — P1 だけではこれを禁止できない点が本 PR 最大の学び) | 再構築前 truncate の三重ゲート(rocksdb かつ **slave ロール** かつ **ソース生存確認済み**、[`handler_reconstruction.cc`](../src/lib/handler_reconstruction.cc#L102-L146))+ Active 指定の役割変更は再構築しない([`cluster.cc`](../src/lib/cluster.cc#L1578-L1591)) | データ保全不変条件 [`activeMasterHoldsData`](../flare_operator/FlareOperator/StateMachine/GlobalModel.lean#L317) が failover/ゾンビ/幽霊の全シナリオで成立(`data_*_ok`)。truncate ゲートは仕様として定理化: [`truncate_gate_preserves_last_copy`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L230) と **[`ungated_truncate_destroys_last_copy`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L237)(ゲートを外す変更はモデルのコンパイルが通らない)** | pvc-data-survival / backup-restore(flush_all 全損→checkpoint から全キー復元) |
| P4 | **新しい事実は古い計算に上書きされない**(pod の再登録を、古いスナップショットから計算した結果が「幽霊」として蘇生させない) | 登録エポック [`FlareNode.regEpoch`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L345) + 「新しいエポック側が丸ごと勝つ」merge([`mergeNodeEntry`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L345)) | [`ghost_not_resurrected`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L308)(バグをそのまま符号化した回帰定理)/ 併せて「登録は merge で消えない」[`mergeClusterState_preserves_keys`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L540)(任意入力) | pvc-data-survival(この修正が green 化の決め手)/ operator-restart(operator 死→状態 reload の同一性) |
| P5 | **過半死では何もしないのが正しい**(circuit breaker)、かつ**復旧は自動再開** | [`circuitBreakerDecision`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L123)(閾値 50%)+ terminal 状態 `EmergencyPaused` | 閾値以上で必ずトリップ [`circuitBreakerDecision_trips`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L143) / 未満では絶対にトリップしない [`_no_trip`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L154) / **トリップ中 FSM は状態も要求も一切出さない** [`emergencyPaused_inert`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L864) | circuit-breaker suite(持続的過半死→トリップ→**15秒2点サンプルでチャーンなし**→容量復帰→operator 再起動なしで回復) |

E2E は計 22 スイート 125 テスト(kind 上の実 StatefulSet + 実 flared)。上記のほか、
スケール操作(out/in)、Blue/Green 移行、WAL 増分同期、設定伝播、バックアップ/リストア
を網羅する。全スイートに「失敗時に operator/flared のログを teardown 前に採取する」
診断フックが入っており、flake は再現ログ付きで届く。

## 形式手法が実際に働いた代表例(5件)

**1. ゾンビ master(モデルが実環境より先に発見)**
「プロセスだけ再起動した空の旧 master が、failover を経ずに master に返り咲く」
経路の疑いに対し、モデルにそのシナリオを書いて実行したところ**数秒で再現**
(CI での再現には1周70分かかる)。修正(Active slave 優先昇格)もモデル上で
設計してから実装し、`scenario4_*` 定理で再発をコンパイルエラー化した。

**2. 幽霊蘇生(自作の安全機構が生んだバグを、仕様の言葉で修正)**
split-brain 修復のために入れた merge ルール「role は FSM が勝つ」が、
pod の**新しい再登録**を古いスナップショット由来の計算で毎 tick 上書きし、
死んだ pod の Master エントリを不滅化していた(CI の診断ログで特定)。
修正は「イベントの新旧を merge が判定できる」ようにする登録エポックの導入で、
[`ghost_not_resurrected`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L308) がバグそのものを回帰定理として封印している。

**3. 最後のコピー消去(「証明済み」の外側にバグは住む)**
削除伝播のために入れた「full dump 前 truncate」が、**master になるノード**の
ローカルデータ(前任者が死んでいる以上、最後のコピー)まで消していた。
E2E が検出。教訓が重要で、**証明済みだった P1(master 高々1)は「空の master」と
完全に両立する** — 言明していない性質は守られない。これを受けて P3
(データ保全不変条件)を仕様に昇格させた。

**4. 意味論の乖離こそがバグの住処(C++ とモデル)**
最後まで残った flake の真因は、モデルが当初から定義していた意味論
「Active 指定の master 割当は再構築しない(ローカルデータが正)」を
C++ が実装していなかったこと。修正はモデルの1行の意味論を C++ に移すだけで、
以後 125 テスト全 green。**発見された実バグは一貫して「モデル外」か
「未言明の性質」に分布し、証明済み・言明済みの領域からは出ていない**
(詳細な層別は詳細資料 §9)。

**5. 既存の定理群が「間違った修正」を却下した(全滅復帰のデータ消失)**
CI が新たな DATA LOSS を検出: partition の master と slave が**同時に**再起動し、
operator の起動猶予中(dead 検出停止中)に再登録すると、自分自身の古い
エントリが席を塞いでいるため「全 partition 満員」→ データ保持ノードが
**Proxy に降格**され、flared は proxy 指定でデータを落とす。最初の修正案
「再登録時に旧 master をその場で復位」は、**既存の
[`scenario4_zombie_not_master`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L167-L170)(ゾンビ)と
[`scenario5_ghost_not_promoted`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L197)(幽霊)が
コンパイル時に反例を出して却下** — TCP 文脈には pod の生死が見えず、
ゾンビと全滅復帰は node map 上で区別不能だからである。採用した設計は
「TCP 側は常に Slave/Prepare で旧 partition に再合流(Proxy には二度と
しない)、master の復位判断は実 pod リストを持つ reconcile 側
([`promoteMasterlessPartitions`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L667))が行う」。
この CI ランそのものは [`scenario6_*`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L207) の
5定理(不変条件維持・master 席の復元・**Proxy 降格が一切起きない**・
復位 master がデータを保持)として封印した。**モデルが正しい修正の形を
先に決め、実装がそれに従った**最も鮮明な例である。

## Q. なぜ「証明したもの」と「動くもの」が同一だと言えるのか

この資料が受けるべき最初の疑いなので、機構・確認手順・限界を明示する。

**機構**: operator は Lean で書かれており、**定理が言及する関数と本番バイナリが
実行する関数が、同一ファイル内の同一定義**である。TLA+ などと違い
「スペックを書き、別言語で実装し、目視で対応させる」翻訳工程が存在しない。
例(P1 の合流点):

- 定理: [`mergeClusterState_atMostOneMaster`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean#L492)([`K8sReconciler.lean`](../flare_operator/FlareOperator/StateMachine/K8sReconciler.lean))は
  `FlareOperator.K8sReconciler.mergeClusterState` について述べる
- 本番: reconcile ループの commit([`Main.lean`](../flare_operator/FlareOperator/Main.lean) の [`commitClusterState`](../flare_operator/FlareOperator/Main.lean#L524))は
  `K8sReconciler.mergeClusterState current ucs` を呼ぶ — 同じ完全修飾名、
  つまり同じ定義

**レビューワーが自分で確認する手順**(flare の知識不要、5分):

```
# 1. 定理が対象とする関数名を確認
grep -n "theorem mergeClusterState_atMostOneMaster" -A 2 \
  flare_operator/FlareOperator/StateMachine/K8sReconciler.lean
# 2. 本番の呼び出し点が同じ関数であることを確認
grep -n "K8sReconciler.mergeClusterState" flare_operator/FlareOperator/Main.lean
# 3. バイナリがその Main から作られることを確認
grep -n "root := \`FlareOperator.Main" flare_operator/lakefile.lean
```

P1〜P5 すべて同じ手順で突合できる(対応表のコード列・定理列がその対の一覧)。

**強制機構**: 定義が共有されているため、実装側を変更すると定理は自動的に
再検査され、性質を破る変更は**ビルドエラー**になる。CI はライブラリ全体
(全定理)をビルドするため、この強制は push ごとに働く。

**この主張が及ばない範囲(正直な境界)**:

| 層 | 「同一」か | 担保 |
|---|---|---|
| 判断ロジック(割当・failover・merge・breaker) | **同一定義**(上記の機構) | 定理 + ビルド強制 |
| IO シェル(いつ・どの引数で呼ぶか: kubectl の結果、TCP の順序) | 対象外 — 証明された関数に**間違った入力を渡す**ことはできる | E2E + 診断フック。実例: 幽霊蘇生バグは merge の定理が成立したまま起きた(古いスナップショットを食わせる境界の問題)。修正は判断材料(登録エポック)を証明層の**内側**に移すことだった — 「境界のバグは、境界を証明側に動かして潰す」が本 PR の運用パターン |
| C++ flared(複製・再構築の実体) | **同一ではない** — 手書きモデル([`FlaredNode.lean`](../flare_operator/FlareOperator/StateMachine/FlaredNode.lean))による近似 | E2E + 単体テスト。実例: Active-shift の意味論乖離はここで起きた(前節4件目) |

## よくある質問(先回り)

**Q. `decide` によるシナリオ定理は、ただのユニットテストでは?**
その通り、具体シナリオの decide 定理の証拠能力はテストと同等である。差は
2点: (1) 実装の定義に直結しているため、実装変更で**必ず**再実行される
(テストは呼び忘れうる)。(2) それとは別に、入力に依存しない一般定理
([`GeneralSafety.lean`](../flare_operator/FlareOperator/StateMachine/GeneralSafety.lean) の任意状態・任意ステップ列、merge の任意入力)が
あり、これはテストが原理的に到達できない全状態空間を覆う。表の「証明」列は
この2種を区別して書いてある。

**Q. モデル(GlobalModel)は本物の分散システムではないのでは?**
モデルの**配線**(メッセージキュー、ステップ順)は近似だが、各ステップが
呼ぶ**判断関数は本番と同一**(前節)。つまりモデルは「本番関数を危険な
順序で駆動するテストハーネス」であり、ハーネス部分の忠実性は E2E が別途
担保する。忠実でなかった箇所(C++ の Active-shift)が実際にバグの発生源に
なったことは、この区別が飾りではないことを示している。

**Q. Lean で書かれた operator を誰が保守するのか?**
正当な懸念で、詳細資料 §9.4 に技術選定の比較がある。要点: 危険な判断は
すべて純粋関数(読みやすく、依存の少ない普通の関数型コード)にあり、
IO シェルは薄い。将来 Go 等へ移植する場合も「pure core を分離し性質を
明文化する」構造だけは維持する価値がある、が本開発の結論である。

## 証明とコードの乖離: 現状

- **乖離なし(共有コード)**: 割当・failover・merge・breaker 判断は、モデルと
  本番が**同一の Lean 関数**を実行する。「モデルを検証した」ではなく
  「本番関数を検証した」が正確
- **乖離あり(明示)**: ① C++ flared の複製・再構築の内部(WAL 転送、dump)は
  モデル外 — 単体テスト + E2E が担保。② IO 層(kubectl、TCP 配線)も同様。
  ③ モデルは逐次で、FSM/TCP の実インターリーブ自体は生成しない — ただし
  合流点(merge)は「任意の両者状態」で証明済みなので、どの交錯順でも
  merge の出力は安全
- **検証プロセスの欠陥(発見・修正済み)**: CI が exe ターゲットのみをビルドして
  おり、**証明モジュールが CI で再検証されていない期間があった**(この間に
  一般証明のコンパイル切れ、および FSM 拡張時から放置されていた liveness 証明の
  破損が潜伏)。現在は CI が全証明をビルドし、**この種の腐敗はビルド失敗として
  現れる**。「緑の意味」を疑って検証経路自体を確認したことは、本資料の主張の
  信頼性の裏付けとして明記しておく

## 信じすぎてはいけない点(限界)

- 証明は「言明した性質」しか守らない(上記3件目の教訓)。言明済み一覧が
  上の表であり、**表にない性質は証明されていない**
- E2E は kind(単一 Docker ノード)上であり、実マルチノード・AZ 分散・実データ
  規模での挙動(再構築時間、猶予期間の妥当性)はステージング検証が別途必要
- liveness(いつか必ず収束する)は9つの公平性等の仮定下の証明であり、
  safety(壊れない)と同格の強さではない

## レビューワーへの提案

P1〜P5 の各行について「コード列の関数を開き、定理列の言明がその関数を
対象にしていること、E2E 列のテストがその性質を assert していること」を
1行ずつ突合するのが、flare の内部知識なしで本 PR を検証する最短経路である。


---

## 付録: 実物のコードで見る「証明」— 予備知識なしで読むためのサンプル

証明や TLA+ の経験は不要である。この付録の目的はひとつ:
**「証明」と呼んでいるものが、普通のコードの隣に置かれた
「コンパイラが検査する日本語の文」にすぎない**と体感してもらうこと。
題材は最重要性質 P1(master は各パーティション高々1)の実コード。

### ステップ1: まず普通の関数(本番コード)

master を割り当てる場所を探す関数。Lean だが、Go や TypeScript の
つもりで読めばそのまま読める(出典: [`Reconciler.lean:18,48-56`](../flare_operator/FlareOperator/StateMachine/Reconciler.lean#L18-L56)。①②③のコメントのみ本資料の注釈):

```lean
-- 「パーティション i に master がいるか?」— nodeMap を線形に見るだけ
def hasMasterForPartition (state : FlareClusterState) (pIdx : Nat) : Bool :=
  state.nodeMap.any (fun (_, n) =>
    decide (n.role = FlareRole.Master ∧ n.partition = Int.ofNat pIdx))

-- 「master が空いている最初のパーティションを探す」
-- ① i がパーティション数を超えたら「空きなし」(none)
-- ② パーティション i に master がいれば次へ
-- ③ いなければ i を返す ← ここが P1 の心臓部:
--    この関数は「master がいない場所」しか返せない作りになっている
def findPartitionNeedingMasterAux (state : FlareClusterState) (numPartitions : Nat)
    (i : Nat) (fuel : Nat) : Option Nat :=
  match fuel with
  | 0 => none
  | fuel + 1 =>
    if i >= numPartitions then none                        -- ①
    else if hasMasterForPartition state i then             -- ②
      findPartitionNeedingMasterAux state numPartitions (i + 1) fuel
    else some i                                            -- ③
```

割り当て側(`autoAssign`)はこの関数が返した場所**にだけ** master を置く。
つまり「二重 master を作らない」ことの実質は③の1行に懸かっている。

### ステップ2: その関数についての「文」(これが証明)

上の関数のすぐ下に、こう書いてある(出典: [`Reconciler.lean:79-83`](../flare_operator/FlareOperator/StateMachine/Reconciler.lean#L79-L83)):

```lean
theorem findPartitionNeedingMaster_spec (state) (n pIdx) :
    findPartitionNeedingMaster state n = some pIdx →
    hasMasterForPartition state pIdx = false := by
  ...(証明本体。読まなくてよい)
```

読み方: `theorem 名前 : 文 := by 証明本体`。
**読むべきは「文」の部分だけ**で、これは日本語に直訳できる:

> 「findPartitionNeedingMaster が pIdx を返したなら、
>   そのパーティションに master はいない」

`:= by ...` 以下は「この文が正しい理由」で、**人間ではなく Lean の
コンパイラが検査する**。だからレビューワーは証明本体を読む必要がない —
確認すべきは (a) 文が意図と一致しているか、(b) 文中の関数名が
本番コードと同じものか(grep で確認できる。本文「同一性」の節参照)、
の2点だけである。

型注釈が「この関数は Nat を返す」をコンパイラに検査させるのと同様に、
theorem は「この関数は master のいない場所しか返さない」を検査させる。
**やっていることは型チェックの延長**であり、それ以上の神秘はない。

### ステップ3: バグをそのまま封印した「文」(ユニットテストとの地続き)

実際に起きたバグ(ゾンビ: 空の旧 master プロセスが復活して master の座を
奪い、パーティションのデータが静かに空になる)は、修正後こう封印されている
(出典: [`VerifiedSafety.lean:167-170`](../flare_operator/FlareOperator/StateMachine/VerifiedSafety.lean#L167-L170)):

```lean
theorem scenario4_zombie_not_master :
    ((scenario4_zombieResurrection.operatorState.nodeMap.lookup
        "node-0:11211").map
      (fun n => n.role == FlareRole.Slave && n.state == FlareState.Prepare))
    = some true := by
  decide
```

直訳: 「ゾンビ復活シナリオを最後まで実行したとき、復活したノード
(node-0)は master ではなく、Slave/Prepare(= 新 master からデータを
作り直してからでないと提供できない状態)になっている」。

`by decide` は「シナリオを実際に実行して確かめよ」という指示で、
**これは実質ユニットテストである**。ただし2点だけテストより強い:
実装の定義に直結しているので**実装を変えると必ず再実行される**
(呼び忘れが存在しない)こと、そして CI がこのファイル全体をビルドする
ので**この文が偽になる変更はコンパイルが通らない**ことだ。

### まとめ(この付録で言いたかったこと)

- ステップ1は普通のコード、ステップ3は実質ユニットテスト。
  「証明」の大半はこの2つの中間にある読み物であり、
  **専門知識が要るのは証明本体(読まなくてよい部分)だけ**
- 例外は一般定理([`GeneralSafety.lean`](../flare_operator/FlareOperator/StateMachine/GeneralSafety.lean): 任意の状態・任意の操作列で P1 が
  保たれる)で、これはテストでは原理的に書けない主張である。ただしそこでも
  レビューワーの仕事は変わらない — **文を読み、意図と一致するか判断する**
