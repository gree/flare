# 通常運用（drain・ノード更新・突然停止・通信分断）— 設計と受入表

2026-10-19。最優先の開発タスク（ユーザー指示「claude code にやらせて」）。snapshot push は低優先度。
範囲はリポジトリ開発と隔離 kind CI だけ。pf-dev / AWS での障害注入・ノード操作・safe-to-evict 解除・
タグ / publish / 環境変更の承認ではない。前提資料は `docs/review-safe-eviction-2026-10-14.md`（v2、以下 R2）。
本書はその設計（§4）を引き継ぎ、突然停止・通信分断・CI を足して、保証範囲と実装順を決める。

**現時点の状態: 設計のみ。実装なし、CI 証拠なし、レビューなし、本番承認なし。**

## 1. 受入表

列: 保証 = 試験で示して主張するもの / 非保証 = 明記して主張しないもの / 現状 = 今のコード（rc67, cfed6a8）の振る舞い（推定は推定と書く）。

| | 保証（目標） | 非保証 | 現状との差 |
|---|---|---|---|
| **A 計画退避（標準 `kubectl drain`、Eviction API、PDB 尊重）master** | 削除許可の時点で、成功応答済みの全 write（client・proxy・cross-cluster 受信・reaper / purge などの内部 mutation を含む）が別 worker の同一 lineage のコピーに適用済み。旧 master は write を受けない（fence 中は client に明示エラー）。後継が master。その後、別 worker で再構築して冗長性が戻るまで次の退避を許可しない | 許可後の独立故障（残ったコピーの喪失など）。admission を通らない経路（`kubectl delete pod`、`--disable-eviction`、node-pressure、ノード障害）。容量不足時の冗長性回復（方式 b の場合、§3 判断点 1） | 退避を止める制御がない（静的 PDB は Ready だけを数える。preStop は sleep）。交代は削除開始後に猶予内で行い、fence も barrier もない。旧 master が受理済みで replica 未適用の write は失われうる（R2 §3.2）。**multi-node / drain の CI は存在しない** |
| A' 同 replica | master が全データを持ったまま残る。再構築完了まで次の退避を拒否 | 単一コピー期間の master 喪失 | replica が Ready なら PDB は許可。follow 不適格でも Ready なら通る |
| **B 突然停止（worker 丸ごと到達不能）** | 適格なコピー（R3 / 履歴で適格）だけを昇格する。良いコピーが戻った時に古いコピーを優先しない（現行の promotion-by-reason）。昇格と、別 worker での再構築完了を観測・記録する。停止→同じデータで復帰と、tmpfs 喪失による置換を別 fixture で示す | **非同期複製なので、replica 未適用の成功応答 write は失われうる（無損失としない）。** 失われた範囲は NOT LOSS-FREE として記録し、件数は測定値でだけ言う。到達不能 node 上の Pod の置換（StatefulSet は同名 Pod を作らない）は判断点 3 | 昇格は Pod Ready 条件（kubelet 不達で node controller が False にする、約 40〜50 s）経由で起きる見込み（**未測定**）。到達不能 node の Pod は Terminating に残り、StatefulSet は置換しないので **冗長性が戻らない**（推定、試験で確認する） |
| **C 通信分断（client は両側に届く）** | 測定: 旧 master と新 master が同時に write を受ける時間帯の有無と長さ、双方の受理件数、復旧後にどちらが残るか。kind の遮断を実 AZ 障害の証明にしない | 任意の分断で可用性と無損失を両立すること（主張しない）。二重 write を防ぐ仕組みは現状なし → 判断点 2（製品ギャップとして設計レビュー） | flared に master リース / 自己降格はない。operator は「Ready だが接続できない」では failover しない（EV-11）が、node 自体が NotReady になれば failover する。分断側の旧 master は client write を受け続ける見込み（**二重 write の可能性、未測定**） |
| **D 退避保留** | replica 遅延・断線・不適格コピー・退避先不足・容量不足では旧コピーを壊さず削除許可を保留し、理由を通知（Eviction 応答のメッセージ、event、metric）。再構築と冗長性回復まで次の退避を許可しない。同時要求・operator 再起動・古い Pod UID / grant・応答喪失・期限切れを決定的停止点で試験 | 許可後〜削除までの TOCTOU（検知のみ、R2 §4.4 最終行） | 保留の仕組みなし（静的 PDB のみ） |

## 2. 方式（R2 §4 を採用、差分のみ）

- 退避（A / D）: R2 §4 のとおり。初回 Eviction は拒否して非同期 prepare（fence → in-flight 排出 → 固定 barrier → 別 node での適用確認 → 交代 → 旧 master の write 拒否確認）、準備完了後の再要求だけ許可。**preStop で初めて同期を始める方式は採らない。** grant は Pod UID / boot / copy / history / partition / attempt に束縛して CR status に永続化。admission は判定と記録だけで待たない。dryRun は副作用なし（`NoneOnDryRun`）。Eviction object は Pod ラベルを持たないので **namespaceSelector + Pod 名からの解決**で捕捉する（objectSelector は使わない）。
- 突然停止（B）: 既存の failover / promotion-by-reason を使う。新規は試験と、置換の方針（判断点 3）。
- 分断（C）: まず測定。防ぐ方式は判断点 2。

## 3. 判断点（レビューに出す。未承認のまま実装しない）

1. **容量方式**（R2 §6-1）: (a) make-before-break（退避前に第 3 のコピーを別 worker に作って適格化、一時的に資源 3 倍）か、(b) 退避後は単一コピー運転で、冗長性回復は保証しない（次の退避は拒否）。
2. **分断時の二重 write を防ぐ新しい保証**（分散フェンシング）: 例) flared の master リース — operator からの更新が T 秒途絶えた master は自ら write を拒否する。可用性を下げる（operator 障害・制御経路の断で write 停止）ので、採るかどうか・T・対象経路はレビュー事項。**同期 ACK（replica 適用後に client へ成功）** も同じく新しい保証で、遅延と可用性に影響する。どちらも未承認。
3. **到達不能 node 上の Pod の置換**: K8s の `node.kubernetes.io/out-of-service` taint（非正常シャットダウン）や強制削除は、その node が本当に止まっている前提でだけ安全（StatefulSet の at-most-one）。operator が自動で行うか、人手手順にするか。
4. **fence 中のクライアント write エラー**（R2 §6-2）を許容するか（数秒）。
5. 数値 SLO（エラー時間・復旧時間）は決めない。まず CI で測定値を出し、提案する。

## 4. 実装順

1. **試験基盤**（判断を待たずに進める）: multi-node kind（control-plane + worker 3 以上）。master / replica を別 worker に置いたことを検査（同 worker なら PRECONDITION NOT MET）。再配置先の worker を確保。単独 suite で実行可能、CI leg を独立。成果物として試験条件・対象 SHA・時系列・ACK したキー値・各コピーの状態（own copy dump、役割、LSN）を保存。ハーネスは観測欠落を 0 / 成功にしない。local 応答と proxy 応答を区別する。
2. **現状の再現 fixture**（旧コードでの失敗・挙動の記録）: A0 master worker の `kubectl drain`（継続書き込み）、A0' replica worker、B0 worker コンテナ停止 → 復帰 / 置換、C0 master-replica・制御経路の遮断（client は両側に届く）で二重 write 測定、D0 遅延 replica で drain。
3. **flared**: fence（TTL・全 mutation 入口・token）、in-flight カウンタ、barrier 用の stat、適用遅延の試験 knob。
4. **operator**: disruption 状態機械（CR status に永続、prepare / grant / abort / 期限）、validating webhook（証明書配布を含む）、preStop の後始末化、通知（event / metric / Eviction メッセージ）。
5. 単体（状態機械・grant 束縛・中断の決定的停止点）→ 対象 E2E の対照（旧コードとの比較）→ 候補を固定して全体 CI。全体 CI を小変更の初検証に使わない。成功するまで rerun して閉じない。
6. 判断点 1〜3 の結論に従う追加実装（未承認の間は作らない）。

## 5. 報告の区分

各項目を 実装済み / CI 済み（固定 candidate の全体 CI） / レビュー済み / 本番承認 に分けて報告する。現時点ではすべて未。既存の公開 tag（rc67 など）は変更しない。

## 6. 現状の再現（c27ff35、E2E 39197113290 / 39197119445、multi-node kind）

ガードなしの現行コード。single-suite なので候補の証拠ではない。

| シナリオ | 結果 | 測定値 |
|---|---|---|
| A master の drain | 合格 | drain 完了（rc 0）。ACK 済み write の欠損は master・replica とも 0。冗長性の回復まで 70 s。書き込みは各 writer で約 30/s、遅延の注入なし。**後継への遅延がないと、喪失の窓がほぼ開かない**（A は acfa862 で後継の worker に 100 ms の netem を入れて再測定する） |
| A' replica の drain | 合格 | 欠損 0、冗長性の回復まで 77 s |
| **D replica 遅延中の drain** | **不合格（ギャップを再現）** | 後継を遮断した状態で drain が完了した。静的 PDB は保留しない |
| B worker 停止 → 同じデータで復帰（PVC） | 合格 | 昇格まで **151 s**。内訳: 停止 → Pod Ready=false が +44 s（node monitor grace）、Ready=false → 昇格が約 107 s。後者は `FLARE_UNREADY_DEAD_CYCLES=6` サイクル分で、到達不能時は 1 サイクルが延びている（推定、未分解）。手動操作なしで 180 s 待っても**冗長性は戻らない**（Pod は到達不能 node 上に残る）。worker の復帰後に回復した。ACK 欠損 0 |
| B' worker 停止 → tmpfs 喪失 | 合格 | 昇格まで 168 s。自動回復なし。停止を確認した上で Pod を強制削除し、空き worker で再構築された（判断点 3） |
| C 複製経路と制御経路の切断（node は Ready） | 合格 | master は 1 つのまま（failover なし）。二重 write 0、ACK 欠損 0 |
| C' master の worker を control-plane からも切断 | 判定不能 | 150 s の切断中に failover が起きなかったので、二重 write の時間帯に届いていない（acfa862 で 330 s に延長） |

## 7. 実装の現状（acfa862、未レビュー、全体 CI 未実施）

- flared: write fence（`fence arm|release|status`、TTL、in-flight カウンタ、全 mutation 入口と reaper / lazy expiry）。C++ 単体試験 `test_write_fence` は CI で初めてコンパイルする
- operator: `StateMachine/Disruption`（純粋）、`EvictionGuard`（webhook と prepare）、`status.disruption`（CRD）、webhook サーバ（127.0.0.1、TLS は sidecar）。単体 596 合格
- chart: `evictionGuard`（既定 OFF）
- E2E: `evictionGuard` を有効にしたハーネス。A / D はガードあり、`*-control` は同じ SHA でガードなし（対照）

## 8. 対照の結果（acfa862、E2E 39217253658 / 39217262413 / 39217270748、single-suite）

旧 SHA の証跡。下の §9 の修正の成功扱いにはしない。

| シナリオ | ガードあり（node-ops-drain / -hold） | ガードなし（*-control） |
|---|---|---|
| A master の drain（後継の worker に 100 ms 遅延） | 合格。ACK 欠損 master 0 / replica 0。冗長性の回復まで 130 s。**fence 中の client エラー: svc writer 8095 件 / peer 150 件、約 46 s の窓**（判断点 4 の測定値） | **不合格: ACK 済み write 2 件が新 master から欠損**（ギャップを再現） |
| A' replica の drain | 合格、欠損 0、回復 91 s | （未実施） |
| D 後継遮断中の drain | 合格: drain は完了せず、master は削除されず、理由が requester に届いた | **不合格: 後継が遮断されたまま drain が完了** |
| C 複製・制御経路の切断 | 交代なしを観測（Pod は Ready のまま、operator は接続できないだけなので設計どおり交代しない）。二重 write 0（operator map からの推定）、ACK 欠損 0 | — |
| C' master の worker を control-plane からも 330 s 切断 | **シナリオ不成立（注入が成立していない疑いが強い）。** 交代なしを観測、交代後の安全性は未実施。通常 failover・二重 write 防止の受入合格ではない（当時の test は dualAcks=0 / lost=0 だけで pass にしていた） | — |

### 8.1 C' で failover しなかった件（追加レビュー 2026-10-19）

既存 artifact（39217270748、acfa862）で確定したこと:
- 切断 08:55:37 → 復旧 09:01:10 の間、144 回のサンプルすべてで master Pod は `ready=true`。**Pod NotReady は未観測。Node の状態（Ready 条件・Lease）は当時採っていないので未確認**
- operator は `READY but the OPERATOR cannot connect`（1 回目 / 10 回目のプローブ）を記録したが、Ready の Pod を接続不能だけでは dead にしない（EV-11 の設計どおり）ので昇格しなかった
- operator → master Pod と replica → master Pod（Pod アドレス、FORWARD）の切断は成立していた（operator の接続不能、replica の `follow=disconnected`）

仮説（強く支持されるが未確定）: worker ↔ control-plane（node アドレス 172.18.0.3 ↔ 172.18.0.4）のルールは各 kind コンテナの FORWARD にしか入れていなかった。kubelet → API server の通信は各コンテナ自身の名前空間で OUTPUT / INPUT を通るので、FORWARD では落ちない。そのため node heartbeat が止まらず、node は Ready のままだった。当時の artifact にはルールのカウンタも、Node Ready / Lease の時刻も、実接続の検査もないので確定はできない。operator の timeout や昇格条件は変えていない。

修正（ハーネスのみ）:
- 経路ごとに chain を選ぶ: Pod アドレスの組は全 node の FORWARD、node アドレスの組は送信側の OUTPUT と受信側の INPUT（両方向）。全ルールの設置成功を必須にし（kind node が空・対象 node が無ければ前提不成立）、復旧前に各ルールの drop カウンタを記録（`cuts.txt`）。読めないカウンタは前提不成立
- 実通信で成立を立証: replica → master と operator → master は TCP 接続が開かないこと、worker → API server（`curl https://<cp>:6443/healthz`）は切断前に開き切断後に開かないこと、client（debug pod）→ 旧 master は ACK が続くこと
- C' はさらに、node Ready が Unknown / False になり、Lease の renewTime が切断 60 s 後以降に進まないことを観測しない限りシナリオ不成立（PRECONDITION NOT MET）
- 注入の失敗を成功扱いしない（`installCuts` の結果を必須に）。途中で失敗しても `finally` で設置済みのルールを外す（D の遮断も同じ）
- 判定: 二重 write は operator map ではなく、両側の node 自身の view（`own_role` / `node_map_version` / boot。client が両側から読む）で前後のサンプルが一致する時刻だけ local / forwarded と判定し、旧 master の local ACK と新 master の local ACK が同じ時間帯にあることを要求。判定できない ACK は UNOBSERVABLE で fail（0 扱いしない）
- 追加レビュー（8a9be61 に対して）で固定した穴: 昇格は**切断中に**replica 自身の view が master だった場合だけ数える（heal 後の初昇格は failover ではない）。C' の pass には切断中の新 master の local ACK が必須（0 件・全要求 error は NOT VERIFIED）。C も旧 master の local ACK が 0 件なら NOT VERIFIED。own view は role・map version・boot の一致を要求し、strict bracket で判定する: 書込の [送信, 応答] 区間（writer が送信時刻も記録）より前に**終わった**読み取りと、後に**始まった**読み取りを使う。両者は 12 s 以内で、その間に重なる読み取りもすべて同じ view でなければならない。時刻は全部 debug pod の時計（writer と同じ）。probe は、timeout による接続不能（DROP の結果: `timeout` 124 / curl 28）だけを遮断とする。実行不能・拒否・その他は Unknown（前提不成立）。Pod 間の経路は切断前に OPEN であることも必須
- **これは役割の読み取りからの推定で、要求ごとの処理経路の直接証拠ではない。** したがって C / C' の pass は測定上の pass であり、受入合格には使わない。受入に使うには、request / connection ID に結び付いた mutation 結果の trace（flared 側の実装）が必要（未実装）
- C' で交代なし = **NOT VERIFIED**（fail、緑にしない）。交代あり・二重 write = PRODUCT GAP（判断点 2）。交代あり・二重 write なしは、旧 master の最後の local ACK が新 master の最初の local ACK より前であることを要求。昇格を強制する操作はしない
- writer の記録が読めない場合（`stopWriter` 失敗）は UNOBSERVABLE で fail（A / B / C すべて。以前は `getD []` で「ACK 欠損 0」になりえた）
- B は、適格 replica の昇格が観測期間（300 s、ハーネスの上限で SLO ではない）内にあることと、昇格後に ACK が再開したことも要求

## 9. レビュー指摘（2026-10-19、対象 6f65ab7）への対応

| # | 指摘 | 修正 | 反例テスト | 残余 |
|---|---|---|---|---|
| 1 | fence の TTL 切れ後に古い barrier を再利用しうる | flared: `fence_generation`（未 arm → arm の遷移ごとに +1、同一 token の継続 re-arm は不変）と、一度のロックで読む `write_fence::snapshot`。operator: fence を初めて見た時の generation（と boot id）を記録し、以後の各 step で一致を要求。不一致・未 arm = 継続性の喪失 → barrier を無効化して fencing に戻る（再 drain・barrier 再取得・後継の再追従）。committed map の切替後の喪失は abort（grant しない）。target の再起動（boot 変化）は abort | C++ `test_generation_proves_continuity_across_ttl`（TTL 跨ぎで gap 中の write が受理され、同 token の再 arm で generation が変わる）。Lean `#1 fence lapse ...`（gap で seq 60→75、古い barrier 60 では進まず、新 barrier 75 を要求）、未 arm、切替後の喪失、boot 変化 | grant 後の期限切れは、旧 master が自分の map で proxy であることを grant 条件で確認済みなので、再開した write は新 master へ転送される（#2）。切替前に失効して gap で受理された write は barrier の再取得で後継に要求する |
| 2 | switched が operator の desired map だけ。successor を捨てていた | flared: `own_role` / `own_state` / `own_partition`（自分が受理した map）。operator: successor を fencing 時に **固定**（適用位置最大 → key 最小）。switch 確認 = committed map が切替済み、かつ target が自分の map で proxy、かつ固定した successor（同一 UID / boot / copy、Ready）が自分の map でその partition の master、かつ両者の `node_map_version` ≥ committed version、かつ fence が継続。planned switch 中は同じ partition の他コピーを昇格候補から外し（`plannedExcluded`）、commit 時にも他コピーの昇格を abort。grant 時に fence を release しない。切替後の abort では、旧 master が自分の map で master のままなら fence を維持する | Lean `#2 the switch is confirmed from the nodes' OWN maps`（desired map だけ、旧 map version、target が master のまま、successor が slave のまま、successor の boot 変化）、`#2 another candidate appears`、`chooseSuccessor`（候補複数）、`plannedExcluded`、切替後 abort の fence 維持 | 「旧 master の write 拒否」は fence と own_role=proxy で確認し、実際の書込試行による確認はしていない。own_role と node_map_version は別のロックで読む（version は単調なので、保守側にずれるだけ）。昇格時に history epoch は変わるため、切替後の successor の束縛は UID / boot / copy / partition |
| 3 | admission と prepare の並行更新に排他も CAS もない | すべての状態変更を `commit` 1 本にした: プロセス内ロックの下で (a) lease を自分が保持し、開始時と同じ transitions、(b) 開始時と同じ leadership generation、(c) メモリ上の状態が判断の元と同じ、(d) クラスタの状態が判断の元と同じ、を確認してから、サーバ側 CAS（JSON patch の `test` で読んだ値と完全一致を要求、キーがなければ resourceVersion 条件付き merge）で書く。外れたら破棄（admission は「retry」で拒否、prepare は次の pass で再判断）。遅い読み取りはロックの外 | Lean `#3 commit`（lease なし、generation 変化、同時 admission、古い reconcile、読めない status）、`#3 ... compare-and-swap`（patch の形） | E2E での同時要求・リーダ交代・古い更新の試験はまだない（次の対象 suite で追加） |
| 4 | replicaSafe が master items>0 だけで true | `replicaVerdict`: master が Ready で、自分の map でその partition の master、copy が健全（identity 一致・quarantine / partial / restored-unverified でない）。target は R3 eligible で、検証元が現 master の key、検証時の history が master の `rocksdb_source_epoch` と一致し、適用位置が master の latest sequence 以下。読めない = Unknown = 保留。target が空（0 件）なら lineage は不要（master の健全性は必要）。grant に master の key と binding を束縛し、admission と granted 中の毎 pass で再確認（変われば grant 撤回） | Lean `#4 replica`（非空 master で history 違い、検証元違い、master より先、not eligible、Unknown、legacy の空 epoch、master が自分の map で slave、copy 不健全 → すべて保留。毎 pass の再確認で撤回） | 適用位置の比較は repl_applied_lsn（master の LSN 空間）と master の latest sequence |
| 5 | lazy expiry の fence 確認と remove が不可分でない | 削除全体を `write_fence::entry` で覆った（確認と in-flight 計上が 1 つのロック。fenced なら隠すだけ）。試験用 seam `set_entry_hook`（admit 直後、mutation の前に呼ばれる） | C++ `test_expire_lazy_delete_counted_when_fence_arms_mid_delete`（check と削除の間で arm → in-flight 1、削除は barrier に含まれる。fence 中の次の lazy expiry は削除せず sequence も動かない） | 内部 mutation の監査: client / proxy / cross-cluster（op_set / op_delete / op_incr 系。add / replace / cas / append / prepend / touch / gat / decr は op_set / op_incr の `_run_server` を継承）、flush_all、snapshot push、orphan purge、reaper chunk はすべて entry。copy_discard は master では動かない。WAL apply / tombstone 回収は replica 側。メタ CF への書込（master id、generation、history、partition binding）は data を持たず、barrier の後に sequence を進めても保守側（後継により多くの適用を要求するだけ） |

検証の状態: 実装済み、単体試験のみ（ローカル Lean、C++ は CI でコンパイル）。対象 suite の E2E、固定 candidate の全体 CI、レビュー、本番承認はいずれも未。ガードの有効化、pf-dev の変更、safe-to-evict の変更、tag / publish はこの対応に含まない。

### 8.2 partition の targeted run（e51ad45、E2E 39242985724）— 判定はシナリオ不成立 / 観測不足

製品の判定ではない（どちらも fail、ハーネス側の理由）。

- **C'（node 単位）: PRECONDITION NOT MET。** ルールは全 20 本設置され、worker の OUTPUT（172.18.0.4→172.18.0.5）で 62、control-plane の OUTPUT（逆向き）で 243 パケットを落とした。worker → API server の IPv4 probe は切断前 OPEN、切断後 timeout。**それでも node Lease は 10 s ごとに更新を続けた**（node Ready は 107 サンプル中 Unknown 4 回、Pod NotReady 2 回だけ）。仮説（未確定）: kind の docker network は dual-stack なので、kubelet は IPv6 で API server に届いていた。修正: node アドレスの組は両コンテナの全 family（IPv6 は ip6tables）で切り、API probe も全 family で、切断前は全部 OPEN・切断後は全部 timeout を要求する。次の run で IPv6 ルールのカウンタと Lease を見て確かめる
- **C（経路のみ）: UNOBSERVABLE。** ACK 3248 件の経路を判定できなかった。原因（artifact で確定）: 切断直後の probe 中（約 11 s）と、heal 後の待機中に own view の読み取りが途切れ、strict bracket（12 s 以内）が成立しなかった。判定規則は正しく働いた（不明を 0 扱いしない）。修正: 切断直後、probe の後、heal 直後にも読み取る
- Pod 間の経路（FORWARD）は全経路でカウンタが正（46 / 141 / 42 など）。replica → master と operator → master は切断前 OPEN・切断後 timeout

### 8.3 追加レビュー（7fe906f に対して）で直したこと（ハーネスのみ）

- **観測の空白:** own view の読み取りを別タスクの observer（約 1.5 s 周期）にした。ルール設置・probe（timeout を含む）・counter 収集の長さに左右されない。読み取り 1 回は exec 1 回で、前後に debug pod の時計を読む。切断中の読み取り間隔の最大を report に記録する。ローカルの単体試験（周期 100 ms、呼び出し側が 300 ms × 5 回ブロック）で最大間隔 110 ms（上限 250 ms）を確認した
- **kubelet の実 endpoint:** test kind node の `kubelet.conf` の `server:` 行だけを読み（認証情報は読まない）、名前解決の結果、各アドレスの probe（open / timed-out / refused = listen なし / cannot-run）、kubelet の ESTABLISHED 接続先（切断前・後）を `api-endpoint.txt` に記録する。切断対象 = 切断前に open だった経路 + kubelet の実接続先。切断後はそのすべてが timeout であることを要求する。refused の family（listen していない）は要求しない。cannot-run は open 扱いにしない
- **writer の記録:** 完全性を検査する（全行が parse できる、通番 1..N に欠番・重複がない、ACK が 1 件以上ある。途中で切れた最終行だけは除外して報告する）。空・破損・欠番は未観測として拒否する（A / B / C 共通）
- **heal 時の時計:** 読めなければ明示的に UNOBSERVABLE にする
- 判断は変えていない: 昇格条件・operator の timeout はそのまま。これは測定ハーネスの修正で、分断中に旧 master の書込を止める製品の仕組み（判断点 2）は未解決

### 8.4 partition の targeted run（7fe906f、E2E 39256682356）— どちらも UNOBSERVABLE（読み取りの空白）

- **C' は注入が成立した**（初めて）: ルール 24 本（IPv6 を含む）。worker の ip6tables OUTPUT（::2→::5）が 1168 パケットを落とした。Lease は 14:38:26 から更新が止まり（切断 14:38:35）、node Ready は 86 サンプルで Unknown。operator は master Pod の NotReady を 76 s で dead と判断し、14:41:38 に replica を昇格した（`PROMOTION NOT LOSS-FREE`、旧 master は生きていて client が届く状態）。**IPv6 経路の仮説はカウンタと Lease 停止で強く裏付けられた**（kubelet の接続先そのものの記録は 062014f から）
- それでも判定は UNOBSERVABLE（ACK 10877 件 / C は 2789 件の経路を判定できない）: 7fe906f では、probe の手順の間に読み取りの空白が残っていた（追加レビューの指摘どおり）。062014f の observer で直す
- 二重 write の有無はこの run では判定していない（製品ギャップの測定は次の run）

## 11. 分断時に旧 master の書込権限を失効させる — 製品設計の選択肢（提案のみ。未承認・未実装・既定動作は変えない）

### 11.1 何が起きているか（7fe906f の C' で観測）

master の worker が control-plane から切れると、node は Unknown になり、operator は Pod NotReady を 76 s で dead と判断して replica を昇格した。旧 master のプロセスは生きていて、client は届き、旧 master は自分の map で master のまま write を受けて ACK し続ける。operator は旧 master に届かないので、計画退避の fence（operator が arm / re-arm する短期 fence）は使えない。heal 後、旧 master は新しい履歴に従う側として再構築されるので、分断中に旧 master が ACK した write は失われる。**二重 write と ACK 済み write の喪失が同時に起こりうる**（判定は次の run の測定で出す）。

### 11.2 守るべき安全条件（精密化、レビュー 8a4f482）

- **権限区間:** node が「ACK する client write を commit してよい」実時間の区間。client に ACK が届く時刻は権限の時刻ではない（送信済みの ACK がネットワークで遅れて届くことはありうるし、それ自体は違反ではない）
- **S1:** 1 つの partition の旧 master と新 master の権限区間は重ならない
- **S2:** ACK した write はすべて、その node の権限区間の中で commit されている（commit の後、ACK を送る前に権限を検証する。下の 11.4）
- **S3:** S1 / S2 は、分断、遅延・重複・再送されたメッセージ、flared の停止（SIGSTOP、スケジューラの停止、無限に長い停止を含む）と再開、operator の再起動・leader 交代の下でも成り立つ
- **S4:** 権限は時間か世代で失効する。取り消しのメッセージが届くことを前提にしない
- **範囲外（明記）:** 非同期複製なので、旧 master が権限内で commit して ACK し、replica にまだ届いていない write は、昇格後に失われうる（突然停止 B と同じ「無損失ではない」）。リースはこれを防がない。防ぐには同期 ACK（C、条件付き）が必要

### 11.3 選択肢（保証欄は「必要条件を満たした場合」の提案。どれも未証明・未実装）

| 案 | 仕組み | S1 / S2 が成り立つための必要条件（未証明） | 可用性のコスト |
|---|---|---|---|
| A. master の書込リース | 下の 11.4（RQ 方式）。**旧案（受信起点の TTL・送信起点の待ち）は撤回**: 遅延した grant で旧 master の権限が昇格の後まで延びる反例がある（11.5 の 1） | 期限を master 自身の要求送信時刻に束縛する、nonce の一回限りの受理、期限後に届いた grant の破棄、commit 後・ACK 前の権限検証、停止中も進む時計（CLOCK_BOOTTIME 相当）とドリフト上限、grant を出せる leader の権限の終わりが分かること、leader をまたぐ発行停止の永続化 | operator / 制御経路が L 届かないと正常な master も write を止める。failover は少なくとも L + 余裕だけ延びる |
| B. 多数決 | 単なる到達性の多数決ではない。term（世代）付きの投票、1 term に 1 票の排他、会員（voter 集合）の変更手順、票の永続化が要る（Raft の leader 選出と同等） | term と票の永続化、会員変更の安全な手順、時間に頼る部分は A と同じ議論 | witness が必須（1m+1s）。実装は大きい |
| C. 同期 ACK | replica が適用してから ACK する | 同期先の選び方（どの replica が「同期済み」か）、同期済みの replica だけを昇格させる規則、replica 側の永続性（tmpfs では再起動で消える）、同期先が落ちたときに縮退しない（縮退するとギャップが戻る） | 遅延が増える。同期先の障害で write が止まる |
| D. client / proxy の世代トークン | client や proxy が世代を持つ | 直接つなぐ client には効かない | 小 |
| E. 停止が確認できるまで自動昇格しない | **taint・node NotReady・Pod 削除要求は、どれも旧プロセスや書込が止まった証明ではない。**「out-of-service taint を付けたから昇格してよい」は禁止。停止の証明は、実際の fencing（例: cloud API で VM の停止完了を確認する、電源を切る）だけ | 停止完了を確認する仕組み（kind では docker の停止確認、本番では環境ごとの仕組み）。確認できなければ昇格しない | 分断（旧側が生きている）では自動 failover しない |

### 11.4 A を検討する場合の候補プロトコル（RQ、提案のみ）

時刻の起点を、master が**自分で要求を送った時刻**にする。

```
master (旧)                 operator leader               新 master
  q: renew(nonce=n) を送る ─────▶
     （自分の時計で q を記録）      受信、発行停止していなければ
                              ◀───── grant(n) を返す
  r: grant(n) を受ける
     r < q + L なら有効、期限 = q + L   （r は期限に影響しない）
     r ≥ q + L なら破棄
     nonce n は 1 回だけ受理
  ...
                              S: この partition への発行を止める
                                 （権威ある記録に永続化してから）
                              新 master の開始 ≥ max(S, 前の leader たちが
                                 grant を出せた最後の時刻) + L + 余裕 ──▶  開始
```

- grant は「その grant が答える要求を master が送った時刻」から L で切れる。grant がいつ届いても（遅延・重複・再送でも）期限は延びない。期限後に届いた grant は破棄する。古い nonce の grant は無視する
- 発行した側（operator）の記録: 発行を止めた事実と時刻の基準を、leader をまたいで読める権威ある記録（CAS 付き）に永続化してから止める。新しい leader は、前の leader が grant を出せた最後の時刻（前の leader 自身の leader 権限の終わり）より後からしか数えない。**前の leader の権限の終わりを、前の leader 自身が知って止まれること**（leader 権限も要求起点で数え、期限後は grant を出さない）が前提。これがないと、停止していた旧 leader が再開して grant を出し続ける反例がある（11.5 の 3）
- **commit の線形化点:** write は admission で権限を確認し（早く断るため）、**commit の後、ACK を送る前**に、停止中も進む時計で権限をもう一度確認する。期限が過ぎていれば ACK しない（client にはエラー。その write は旧 master のコピーに残るが、heal 後の再構築で捨てられ、ACK されていないので S2 違反ではない）。admission だけの確認では、admission と commit の間の停止で期限後の commit が ACK される（11.5 の 4）
- **時計:** Linux の CLOCK_MONOTONIC は OS suspend 中に進まないので使わない。CLOCK_BOOTTIME（suspend 中も進む）を前提にする。SIGSTOP やスケジューラの停止の間も BOOTTIME は進む。VM の停止（hypervisor による一時停止・live migration）で guest の時計がどう振る舞うかは環境依存で、**ドリフト上限 ρ の仮定がそこで破れうる**。根拠のない最大 write 時間や L(1+ρ) の式で安全とは言わない
- **無限の停止:** commit 後の確認があれば、どこで無限に止まっても S2 は破れない（確認の前で止まれば、再開時に期限切れで ACK しない。確認の後で止まれば、commit は権限内で済んでいて、ACK が遅れて届くだけ）。S1（権限区間が重ならない）は、新 master の開始が旧 master の期限より後であることだけに依存し、旧 master の停止の長さには依存しない
- **flared の再起動:** リースはメモリにだけ置く。再起動した flared はリースなしで始まり、新しい要求から数え直す
- **更新できないとき:** 期限が切れた master は write を拒否する（可用性の代償。read は別の判断）

### 11.5 反例（設計モデル `StateMachine/WriteLeaseModel.lean` と単体試験 `leaseChecks` で再現。モデルは製品コードではない）

1. **受信起点の TTL（撤回した案）:** L = 10。t0 に grant を送る → 20 s 遅延 → 旧 master が t20 に受信し、t30 まで有効。送信起点で待つ operator は t11 に新 master を許可 → **t20〜t30 で重なる**
2. **RQ:** 同じ遅延（要求 t0、grant の到着 t20 ≥ t0 + L）は破棄される。速やかな grant（到着 t2）は [t2, t10)、新 master の t11 とは重ならない。重複・再送した grant は期限を延ばさない
3. **leader 交代:** 停止していた旧 leader が t15 に再開し、t14 に送られた要求に grant → 旧 master は [t15, t24)。新 leader が自分の停止時刻（t0）だけから数えると t11 に開始して**重なる**。旧 leader が grant を出せた最後の時刻（t15）から数えると t26 で重ならない（旧 leader が自分の期限で止まれることが前提）
4. **停止（pause）:** 期限 t10。t5 に admission → 停止 → t15 に commit。admission だけの確認では ACK される（**期限外の commit を ACK**）。commit 後の確認（t15）では ACK しない
5. commit が t8（期限内）で、確認の前に停止して t12 → ACK しない（未確定。ACK されていないので違反ではない）。停止なし（確認 t9）→ ACK、権限内の commit

### 11.6 ユーザー判断に上げる点（既定動作は黙って変えない）

1. operator や制御経路が L 届かないときに、**正常な master の write が止まる**ことを受け入れるか（A / B の本質的な代償）。ただし、この承認で A の方式や L の値が安全になるわけではない（上の必要条件の証明・レビューが別に要る）
2. A を実装・検証するまでの間、旧 master が生きている可能性がある unready による昇格（今は 30 s で dead → 昇格）を続けるか、E（停止の確認ができるまで昇格しない）に寄せるか
3. 同期 ACK（C）の条件（同期先・昇格・永続性）を満たす前提で、遅延と可用性を払うか
4. 期限切れ中の read を許すか

提案: 方式の採用や既定変更はまだしない。次は (a) C' の測定（二重 write と ACK 喪失の件数）を出す、(b) RQ 方式の必要条件（特に leader 権限の終わりと発行停止の永続化、VM 停止時の時計）を設計レビューにかける。

### 8.5 partition の targeted run（1b74644、E2E 39273383364）

- **C: 合格（測定。failover の受入ではない）。** 経路の切断を立証（16 ルール、両経路は切断前 OPEN・切断後 timeout、client は届く）。両 Pod は Ready のまま、node 自身の view で master は 1 つ、ACK 欠損 0
- **C': UNOBSERVABLE（3409 ACK）だが、artifact では二重 master が読める**（1b74644 の判定は Unknown を先に返すので、二重 write を報告していない。8a4f482 で直した）:
  - kubelet の endpoint: `kubelet.conf` の server は `flare-e2e-control-plane:6443`。worker での解決は `fc00:f853:ccd:e793::4` と `172.18.0.4`、切断前はどちらも open。kubelet の実接続は切断前 `172.18.0.4`。切断後はどちらも timeout。7fe906f より前に Lease が更新され続けたのは、IPv4 を切っても IPv6 で再接続できたためと読める（IPv6 も切った 7fe906f 以降は Lease が止まる）
  - 読み取りの最大間隔は 3 s（上限 12 s）
  - 切断 16:22:40。replica は自分の view で **切断 186 s 後に master**。その後 operator は約 15 s ごとに map の version を上げた。旧 master は自分の view で切断中ずっと master（version は変わらず）、heal 後に proxy
  - つまり **約 170 s、両方が自分の view で master**。旧 master への writer は最後の ACK が heal 後まで続き、replica への writer は replica が master になってから ACK が始まった
  - 3409 件の Unknown は、新 master の version が変わる前後で strict bracket が成立しない区間（role が同じでも version が変われば途中の変化を否定できないので、未判定のまま）
  - report の "0 local / 56293 unknown path" は集計の誤り（サンプルを渡していなかった）。node 自身の view による経路の集計に直した
- 二重 write の判定（推定）と ACK 喪失（直接）は、8a4f482 以降の run で独立に出す
