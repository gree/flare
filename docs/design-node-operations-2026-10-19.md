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

### 8.6 partition の targeted run（280d928、E2E 39287794350）— C' で製品ギャップを測定

- **C: 合格（測定、failover の受入ではない）**
- **C': PRODUCT GAP（判断点 2）。** 判定と独立の findings（report の全文）:
  - 注入: 成立（kubelet の server `flare-e2e-control-plane:6443` は worker で `fc00:f853:ccd:e793::5` と `172.18.0.5` に解決、切断前はどちらも open、kubelet の実接続は `172.18.0.5`、切断後はどちらも timeout）
  - 読み取り: 193 サンプル、例外なく終了。各 pod の読み取りは必要区間（1792432042..1792432392）を前後で覆い、切断中の最大間隔は 2 s
  - 交代: replica は自分の view で切断から 184 s 後（1792432226）に master。旧 master は heal（1792432396）まで自分の view で master。operator のログは unready → dead → `PROMOTION NOT LOSS-FREE` → `PROMOTION committed`
  - **二重 write（推定、own view）:** 旧 master の local ACK 22778 件が新 master が master だった間に、新 master の local ACK 22167 件が旧 master がまだ master だった間にあった（約 170 s）
  - **ACK 喪失（直接、最終 master のコピーと比較）: 少なくとも 47618 件**（`wo_29472`〜`wo_77089`、旧 master が ACK した write）。**総数と開始時刻は主張しない**: ハーネスの不具合で、同じ cluster で先に走った C の writer が `wo_1`〜`wo_29471` = `v1`〜`v29471` を残しており（C の最後の ACK が `wo_29471`）、C' の writer は同じ key と値を `wo_1` から書き直した。そのため C' の `wo_1`〜`wo_29471` は「届いた」ように見えるが、C' の配送の証拠にはならない（この区間の C' の損失は未判定）。「切断の 108 s 後から欠損」はこの重なりで説明がつく（C' の最初の欠損 `wo_29472` = C の最後の key + 1、artifact で確定）
  - 判定のカバレッジ: 切断区間の ACK 102476 件のうち 97086 件を判定、5390 件は未判定（新 master の version が変わる前後）
  - writer の記録: 両方とも END マーカーまで完全
- 製品の意味: 計画外の分断で旧 master が生きていて client が届く場合、現行の自動昇格（unready で dead → 昇格）は二重 master を作り、旧 master が ACK した write を大量に失う。これは §11 の判断（write 権限の失効の仕組み、またはそれまでの自動昇格の扱い）の材料。既定動作は変えていない
- 修正: writer の key と値を suite / test / writer / 開始時刻で一意にした（`writerRunId`、回帰の単体試験あり）。既存の証跡は消さない


## 12. 要件（ユーザー、2026-10-20）と実現方式（提案。未承認・未実装・既定動作は変えない）

### 12.1 要件

| # | 要件 | 守ること |
|---|---|---|
| R1 | master が使えなくても、後継がいなければ止めない（単独で書き続ける） | 「後継がいない」は master のローカルな見え方ではなく、権威ある membership で決める（slave が見えない ≠ slave がいない: 分断の反例） |
| R2 | 到達可能で使える後継がいれば、有限時間で自動的に切り替える | 到達可能は必要条件にすぎない。copy / history / 再構築中などの既存の適格性確認はそのまま |
| R3 | 切り替えの後、旧 master に届く client がいても二重 write にしない | controller から届かないことと、全 client から届かないことは同じではない（C' は client が旧 master に届く分断） |
| R4 | 制御系（operator）を write の単一障害点にしない | operator が落ちても、master と後継がつながっていれば write は続く |

### 12.2 方式（設計モデル `WriteLeaseModel` で反例を確認したもの）

- **権威ある membership:** operator が partition ごとに `{term, master, successors, mode}` を永続化する（compare-and-swap、term 番号付き）。successor は、既存の適格性確認を通り、**master が successor として承認した** replica だけ
- **solo（successor なし）:** master はリースなしで書き続ける（R1）。successor は master の承認なしには作れないので、昇格の対象が存在しない
- **replicated（successor あり）:** master は、operator のリース（要求起点、§11.4）**または全 successor の約束**（約束の間はその successor が昇格を拒否する）のどちらかがある間だけ ACK する。operator が落ちても、successor に届いていれば書き続ける（R4）
- **昇格（R2）:** operator が発行停止を永続化し、どの leader も grant を出せた最後の時刻から L + 余裕を待ち、昇格させる successor が旧 master への約束を持っていないこと、既存の適格性確認を通ることを満たしたら、新しい term を CAS で commit してから新 master にリースを渡す。新 master は新しい term のリースを持つまで ACK しない
- **旧 master（R3）:** リースも約束も切れたら ACK しない。commit 後の確認は、admission の時の grant（term と lease generation）と同じ grant が有効かを見る（別の thread が受け取った新しい grant では ACK しない）
- **遷移の順序:**
  - solo → replicated: master が承認してから（リース / 約束に縛られてから）replica を昇格可能にする
  - replicated → solo: membership から successor を外す commit が先。master はそれを知ってからリースの要求を外す
- **operator の leader 権限:** grant を出す権限も要求起点で数える（leader が自分で Lease の更新を送った時刻から、期限前に止まる）。**K8s Lease を読んだだけで leader 権限があることにしない。** 今の `getLease` は renewTime（wall clock）と現在時刻の比較なので、そのままでは前提を満たさない（実装時に直す対象）
- **環境の前提（保証の一部として明示）:** 停止中も進む単調時計（CLOCK_BOOTTIME）とドリフト上限。VM の一時停止で時計の仮定が破れうる点は残る。client の経路や入口を環境で制限できる（例: 旧 master への client 経路を Service 経由に限り、Service から外す）なら R3 の補強になるが、直接 Pod に届く client がいれば保証にならない

### 12.3 具体例の検査（`leaseChecks`。期限を比較する純関数による例であって、遷移の証明ではない）

- 受信起点の TTL: 遅延した grant で重なる（撤回済み）
- 要求起点: 遅延・重複・再送の grant は期限を延ばさない。停止していた旧 leader の grant は、旧 leader の権限の終わりを数えれば重ならない
- pause: admission だけの確認は期限外の commit を ACK する。commit 後の確認でも、**admission と別の grant**（別 thread が受けた新しい term）で ACK すると期限外の commit を ACK する → 同じ grant に結び付ける
- membership: ローカルに「slave が見えない = solo」とすると重なる。solo → replicated で master の承認前に昇格可能にすると重なる。replicated → solo で successor を外す前にリースをやめると重なる
- operator 停止・successor 到達可能: 約束で書き続け、successor は昇格を拒否するので重ならない
- C'（operator と successor の両方から切れる）: 最後のリース / 約束で権限が切れ、昇格はそれ以降。successor の約束を待たずに昇格すると重なる

### 12.4 残る判断と影響

1. **C' と同じ状況（master が operator と全 successor から切れ、client だけが届く）では、master は L の後に write を止める。** R3 を満たすには避けられない。止まるのはその master にしか届かない client の write だけで、切り替え後は新 master で書ける
2. **L の値:** 切り替えにかかる時間は、検知（今は unready の 30 s 規則）+ L + 余裕。測定してから提案する
3. **非同期複製の損失は残る:** 旧 master が successor から切れた後、リースの残り（最大 L）の間に ACK した write は、昇格後に失われうる（B と同じ「無損失ではない」）。減らすには、successor に届かなくなった時点で約束の更新を止める・同期 ACK（§11.3 C）などの追加の判断が要る
4. 実装の範囲（承認後）: flared（リース・約束・grant に結び付いた commit 後の確認）、operator（membership の永続化と遷移、要求起点の leader 権限、発行停止の永続化）、E2E（C' で二重 write 0、R1 の solo 継続、R4 の operator 停止中の継続）

### 12.5 successor の約束の遷移（レビュー a6ba116 への設計差分。提案のみ、未承認・未実装）

**約束の束縛:** 1 つの約束は (partition, term, membership generation, M の identity = pod UID / boot / copy, R の identity, nonce) に束縛する。M 側の期限は **M が要求を送った時刻 q から P**（自分の時計）。R 側は、受信時刻から P + 余裕の間は昇格を受けないと**記録してから**返事を送る（記録が先、返事が後）。受け取った時点から TTL を延ばすことはしない。

**R（successor）の状態:**

| 状態 | 約束 | 昇格 | 入り方 |
|---|---|---|---|
| FOLLOWING | 発行・更新する | 受けない | 通常 |
| PREPARING | **新規も更新も拒否**（既発行分の期限は記録に残る） | 記録した最後の約束の期限 + 余裕を過ぎ、かつ起動から P + 余裕を過ぎてから受ける | operator の prepare（intent id, generation 付き）を**永続化してから** operator に応答 |
| PROMOTED | 発行しない | — | store が term t+1（master = R）を CAS で commit したことを R が確認し、term を永続化してから write を受け始める |
| （中断） | 再開する | 受けない | 同じ intent id の unprepare、または prepare の期限（下）が過ぎたとき |

- **有限時間（R2）:** 切り替え ≤ 検知 + prepare が R に届くまで + P + 余裕（operator のリースがあれば、その期限の待ちとの大きい方）。operator が R に届くことが前提
- **operator 不在（R4）:** prepare が来なければ R は FOLLOWING のまま約束を続けるので、M と R がつながっていれば M は書き続ける
- **非対称の分断**（operator → M だけ不達、M ↔ R と operator ↔ R は通る）: prepare で R が更新を止めるので、M の約束は最後の要求から P で切れ、M は write を止め、昇格はその後。prepare がないと M は約束を更新し続けて、切り替えが永久に起きない（反例）
- **prepare の期限:** prepare には期限 T を付けて永続化する。T までに昇格が commit されなければ R は自分で FOLLOWING に戻る。operator が prepare の後に消えても、write が止まったままにならない。昇格の commit は T − 余裕より前に限る（未モデル）
- **R の再起動・Pod の置き換え:** tmpfs では約束の記録が消えるので、再起動した R は起動から P + 余裕の間は昇格を受けない。置き換えで identity が変われば、新しい R は M が承認し直すまで successor ではない（古い identity の約束は M 側で q + P に切れる）

**membership の世代:**

- store は `{term, generation, master, successors（identity 付き）, mode, 進行中の intent}` を CAS で持つ。各 flared は見た中で最大の (term, generation) を永続化し、それより古い config・prepare・約束・grant を拒否する
- replicated → solo（successor を外す）は、権威ある事実（Pod の削除・置き換え、明示の除外）でだけ行い、到達できない・一時的に不適格というだけでは行わない（不達 ≠ 後継なし）。CAS で commit してから M に通知し、M はより新しい世代の config でだけ solo に移る。遅れて届いた古い solo の config は世代で拒否する（反例あり）
- 昇格は、intent の generation が store の現在と一致し、候補が現在の successors にいるときだけ CAS で commit できる。外された successor を古い候補情報で昇格させることはできない（反例あり）
- 切り替えの intent（候補、段階、prepare の期限）は store に永続化し、operator の leader が替わったら、新しい leader が続行するか、unprepare で中断する

**イベント列の反例（`leaseChecks`、`WriteLeaseModel` の event model。M・R・store・operator の 1 本の実時間軸、ドリフトなし。2 台の時計・ドリフト・任意の遅延の証明ではない）:**

| 反例 | 規則なし | 規則あり |
|---|---|---|
| 非対称の分断（operator → M だけ不達） | M が更新し続け、60 s まで昇格できない（R2 不成立） | prepare で R が更新を拒否、M の約束は 20、昇格 25 |
| operator 不在 | — | M の権限は更新され続け（70 まで）、昇格なし（R4） |
| R が再起動して約束を忘れる（tmpfs） | 25 に昇格、M は 30 まで有効 → 重なる | 起動から P + 余裕（34）まで昇格を受けない |
| 遅れて届いた古い solo の config | M が無期限に戻り、昇格と重なる | 世代で拒否 |
| 外された successor の昇格 | — | store の CAS で拒否 |
| 返事を先に送って記録が後 | 記録が消えて 16 に昇格、M は 20 まで → 重なる | 22 まで拒否 |

**モデル化していないもの:** 2 台の時計のドリフト、メッセージの消失・重複の一般形、prepare の期限、leader 交代の途中での中断・再開、複数の successor、operator のリースとの組み合わせ。実装の前に、これらを同じ形のイベント列と不変条件で閉じる。

### 12.6 promotion intent の terminal CAS（レビュー 0a3fff2 を受けた独立実装。設計と未配線のコードのみ。runtime 未変更・未承認）

**0a3fff2 のレビュー。** 反例（commit が T より前に store で確定し、結果の到達が T より後。R が timer だけで FOLLOWING に戻り約束を 40 まで再開し、22 に昇格 → 重なる）は正しい。「commit < T − 余裕」を確認しても、結果配送の任意の遅延とは競合を解決しない。モデルが必要とする安全条件と、その可用性の代償:

| # | 安全条件 | 代償（止まる条件・期間） |
|---|---|---|
| S1 | **Unknown（返事を受け取っていない・store が読めない・record が壊れている）では、期限だけで R は約束を再開しない。** 再開は「この intent が cancelled」と store が肯定した時だけ | prepare 後に R から store への経路が切れると R は PREPARING のまま。約束を出さないので M は P の後に write を止める。**store の復旧まで有限時間の保証はない**（operator 不在の R4 は、prepare が来る前までしか成り立たない） |
| S2 | cancel と commit は永続化した intent 上の**同一の terminal CAS**（pending → committed / cancelled）。terminal は反転しない。同じ決定の再送は noop | CAS の往復分の遅延。store の linearizable を前提（未証明） |
| S3 | commit は leader の fencing token が store の現在値と一致する時だけ。新 leader は先に adopt（token をより大きくする）。旧 leader の遅延 commit/cancel は拒否 | leader 交代の間は commit も cancel も保留（intent は残る） |
| S4 | commit は deadline の**前**（排他）、cancel は R の自己 cancel なら deadline から（包含） | deadline を過ぎた commit は拒否されるので、その intent は昇格できず新しい intent が要る（切り替えが 1 回遅れる） |
| S5 | R は昇格の前に、自分の時計で max(store の oldUntil, R 自身が最後に出した約束の終わり) + margin を過ぎていること | 旧権限が長いほど昇格が遅れる（長さは oldUntil の計算次第） |
| S6 | 旧 master は、リース/約束が切れたら（authorityEnd − margin から）ACK しない。solo（権威ある membership で successor なし）は止まらない。solo への戻りは successor 除外の commit の確認後だけ | C' と同じ状況（master が operator と全 successor から切れ、client だけが届く）では L の後に write が止まる（§12.4 の 1）。止まるのはその master にしか届かない client のみ |
| S7 | record が壊れている・未知の version は「無い」と扱わず、refuse | 破損した record は人が直すまで進まない（保守側） |

**モデルの不完全な点（0a3fff2）:** (1) 誰が timer で cancel を打つかが未定義（operator が不在だと cancel する者がいない）→ 本実装では successor の自己 cancel（deadline から、store 経由）を許す。これは 1 つの判断点。(2) store が `oldUntil` を commit の時点で比較しているが、store は M/R の時計と約束を原子的に読めない → 本実装では oldUntil を prepare ack 時に record し（`none` なら commit 不可）、昇格の待ちは R 側の自分の時計で行う。(3) `role` と `oldUntil` を同一の構造体に置いており、分散状態を原子的に読めるように見える。(4) `safe` は活性化の瞬間しか見ない。M が実際に write を止める時刻（M の時計、ドリフト）は入っていない。(5) R の再起動・record の破損・複数候補・membership の世代・2 つの時計は範囲外。(6) 既存の `WriteLeaseModel` の RQ（要求起点のリース）との接続は純関数 `acceptGrant` の例のみ。

**実装（未配線、`flare_operator/FlareOperator/StateMachine/`）:** `PromotionIntent`（Intent、`prepare`/`recordPrepared`/`adoptLeader`/`commit`/`cancel`、versioned の `encode`/`decode`/`readOf`）、`PromotionRefusal`（`mayResume`、`mayPromote`、`onTimer`（role を変えず `tryCancel` のみ）、`onRead`、`renew`、`masterRefusesWrite`、`acceptGrant`、`approveSuccessor`、`membershipRemoved`）、`PromotionIntentChecks`（`flare_unit` に接続）。terminal の 5 つの命題は任意の record/token/時刻で Lean が証明（writer 排他全体の帰納証明ではない）。

**判断点（数値は選んでいない。引数・record の欄）:** prepare の deadline T、旧権限の上界 oldUntil の算出、リース長 L / 約束の P、margin（ドリフト上限）、successor の自己 cancel を許すか（許さないと operator 不在時に R が戻らない）、Unknown で停止を維持する代償の承認（S1）、store の linearizable な実現（K8s の CAS / resourceVersion 等）と leader fencing の実現、commit の `now` をどの時計で測るか。**未実装:** runtime 配線、flared 側の write 拒否、永続化の IO・破損時の運用、membership の世代。

### 12.7 terminal CAS アダプタの実装境界（f4。設計のみ。次のコードの前に書く。runtime 未配線・既定 OFF・未承認）

**置き場所（既存の store を使う）。** operator が永続状態を持つ既存の仕組みは、K8s の ConfigMap を `kubectl get` / `create` / `replace -f`（metadata.resourceVersion 付き）で読み書きする方式（履歴 `{cr}-history`、`Main.lean` の `readHistory` / `persistHistory`。node-map `{cr}-node-map`）。intent も同じ種類の object に置く: ConfigMap `{cr}-promotion-intent-p{partition}`、`data.record` に `PromotionIntent.encode` の 1 行。partition に 1 つの intent record。新しい種類の store・CRD・時計は足さない。

**CAS = resourceVersion。** 読みは (value, resourceVersion) | notFound | error。書きは `replace`（読んだ resourceVersion を載せる）で、他者が先に書いていれば conflict（API が拒否）。初回は `create`（存在すれば alreadyExists）。resourceVersion は不透明な token として等値の比較にだけ使い、大小や時間の意味は持たせない。

**再読して決める場面。**
- conflict: 書いた値は採用しない。再読し、**読み直した record に対して pure の決定をやり直す**（盲目の上書き・同じ値の再送はしない）。試行は有限（fuel）。尽きたら Unknown を返す（commit も cancel も確定したとは言わない）。
- 返事の喪失（replace がエラー・timeout で、書けたか不明）: 結果は Unknown として扱い、再読する。再読した record が自分の書こうとした値と一致すれば「確定」、そうでなければ新しい record に対して決定をやり直す。再読もできなければ Unknown（R は S1 により約束を再開しない・昇格しない）。
- get の error・notFound の区別: notFound（API が肯定した不在）だけが absent。error は absent ではない。

**旧 leader の拒否。** record の `fence` が adopt 済みの最大 token。commit / cancel / prepared の記録は自分の token が record の fence と**一致するときだけ** pure 側で applied になる（stale は staleLeader）。resourceVersion だけでは「今の leader か」は分からない（別の leader が同じ resourceVersion を読んで書ける）ので、leader 権限は record 内の fence で、同時書込の排除は resourceVersion で、二重に見る。新 leader は先に adopt（token をより大きく CAS）する。

**terminal が再起動をまたいで terminal のまま。** アダプタは状態を持たない（関数 + 外部 client）。決定はすべて「読んだ record」に対して行い、committed / cancelled の record に対しては pure の関数が applied を返さない（既証明の定理: terminal からの反転は applied にならない）。プロセスの再起動後は同じ ConfigMap を読み直すだけで terminal が見える。record が壊れている・未知 version のときは absent 扱いにせず refuse（S7）。terminal の record を新しい intent で置き換えることはこの単位では実装しない（intent の世代交代・GC は未設計。create は alreadyExists で拒否）。

**時間（store の時計を使わない）。** K8s API から「store の CLOCK_BOOTTIME」を原子的に読むことはできない。この単位の CAS は時刻を一切読まない。CAS が与えるのは **commit と cancel の排他（terminal は 1 回だけ、どちらか）**だけ。時間に依存する部分は、その判断をする側が**自分の時計で**行い、`now` を引数で渡す:
- 旧権限の終わりを待つのは後継 R が R 自身の時計（node + boot 付き `At`）で行う（S5。`oldUntil` は R の時計の値。他 node の値は `fromRequest` で期間から R の時計に直したものだけ）。
- すべての時刻値は ClockId（node, boot）を持つ。`now` の ClockId が record の `deadline` と違えば pure 側が clockMismatch で refuse する（比較しない。安全側）。アダプタは時計を持たず、`now` を渡す呼び出し側が時計の持ち主を名乗る。
- **残る設計判断（未解決。この単位では決めない）:** `deadline` は 1 つの時計の値なので、(a) leader の commit（operator の時計）と (b) successor の自己 cancel（R の時計）の両方を時間で制限することは、今の record では表せない。片方の時計に揃えた場合、もう片方は clockMismatch で拒否される（commit が拒否される = 昇格しない = 安全側で可用性が下がる）。どちらの時計に置くか、または deadline を 2 つ持つかは承認が要る。
- 旧 master の権限の上界（oldUntil）の値の出し方、L / P / margin の数値は選ばない。

**この単位でしないこと:** runtime への配線（Main・reconcile ループから呼ばない）、flared 側の write 拒否、kubectl を使う実 client（抽象 client と in-memory の fake だけ）、実 API のテスト、intent の世代交代・GC、停止方針の既定値。solo の master は止めず、operator 単独の故障で write は止まらない（アダプタは operator の中の部品で、flared の write 経路に載せない）。

### 8.7 partition の targeted run（a6ba116、E2E 39345347481）— writer の key を一意にした最初の測定

- C: 合格（測定。failover の受入ではない）
- C': PRODUCT GAP。注入成立、切断中に failover あり。二重 write（推定、own view）旧 master 19080 / 新 master 18424 件。**ACK 喪失（直接）67239 件**（key が試験ごとに一意なので、前の試験の残りで「届いた」ように見える分はない）。判定のカバレッジ 84145 / 88869 件、writer の記録は完全

### 12.6 flared 側の write authority（実装済みの部分と、未配線の入口。C' は完了していない）

**（integ/cprime での更新: 下の表の「未」は §13.1 で閉じた。floor は term だけで fence する（§13）。operator 側と E2E は §13 に配線した。以下は前回時点の記述）**

実装: `src/lib/write_fence.{h,cc}`（既存の fence と**同じ mutex・同じ `entry` の検査路**。第二の gate は作っていない）、試験 `test/lib/test_write_authority.cc`。

- **grant** は partition・term・membership generation・自ノードの pod UID / boot id / copy id・自分が送った request の nonce に束縛される
- **時間:** 自ノードの CLOCK_BOOTTIME。期限は**要求を送った時点** + ttl。受信時刻は入らない。期限後に届いた返事、pending でない nonce（古い・重複・再起動前）、古い term / generation、revoke 済みの (term, generation) 以下は拒否。revoke は後から着く古い grant に勝つ。更新で期限は短くならない
- **solo:** grant が `solo`（権威ある membership に successor なし）と明示する時だけ期限なし。operator に届かないだけでは solo にならず、期限切れ = 拒否
- **既定は OFF**（既存の動作のまま）。`write_fence::authority_set_enabled(true)` は test / admin seam で、本番の既定でも設定項目でもない。ttl は試験のパラメータ（既定値なし）
- **apply 点への束縛（P1）:** ACK の拒否だけでは古い request が storage を書き戻す（term 1 の `K=v1` が admission 後に止まり、term 2 の `K=v2` が ACK された後に再開すると K が v1 に戻る）。entry は storage 書き込みの直前に `apply_begin()` で admission 時の権威がなお現在のものか（revoke / term / generation / identity / engine 切替が無く、**admission 時の自分の期限**が過ぎていないか）を検査し、書き込みが戻るまで apply 区間を開く。偽なら storage を書かず forward もせず `SERVER_ERROR write authority lost before apply`。forward の直前は `still_authorized()`（偽なら forward せず、後段の `ack_ok()` も偽）
- **lock 順序（監査済み）と、apply 区間が保証すること:** `_apply_rw`（entry は共有で storage 書き込みの間だけ保持。権威の変更 = revoke / 新 term / generation / identity / engine 切替 / floor 引き上げは排他で取る）→ storage の wholelock → key の slot lock。`_mutex` は最内で、数個の load/store の間だけ・他の lock を取らず・storage 書き込み、forward、sleep、callback をまたがない。slot lock 配下から `_apply_rw` は取らない（storage_rocksdb の lazy expiry の `entry` は `_mutex` のみ）。**同 term / generation の更新は排他 lock を取らない**。排他 lock は writer 優先。
  - **保証（これだけ）:** 権威の変更（term 変更・revoke・floor 引き上げ）は、開いている apply 区間が閉じる（drain される）まで有効にならない。したがって、変更の**前**に admission された書き込みは、その変更が有効になった**後**には apply できない（apply_begin が偽になる）。同一 key の反例（term 1 の `K=v1` が admission 後に止まり、term 2 の `K=v2` が ACK された後に再開）はこれで閉じる
  - **保証しないこと:** 「deadline が key slot の内側で再確認される」とは言わない。apply 区間は storage 自身の slot 待ち（wholelock / slot lock の待ち）を**含む**ため、deadline の検査は apply_begin の時点であり、slot を取った時点ではない。apply_begin の後に deadline が過ぎても、区間が開いている書き込みはその書き込みを終える（旧 deadline 内で admission・開始した書き込み）。`_apply_rw` は node 全体で 1 つ（partition 別ではない）ので、ある partition の権威変更は他 partition の書き込みの drain も待つ（正しさには影響せず、待ちが増えるだけ）
- **通常の更新（P2）:** 同 term・同 generation の grant は権威を変えない（serial を進めない）。admission 済みの entry は**自分の期限**まで完了できる（新しい TTL に付け替えない）。期限後・revoke・新 term / generation・identity 変更は拒否。ACK 直前の `ack_ok()` も同じ判定
- **clock 失敗:** CLOCK_BOOTTIME が読めない時は `authority_clock_failed` を返し、有効判定・admission・apply・ACK・request 送信（nonce 0、受理されない）すべて fail closed（solo も）。未初期化の timespec は使わない
- **残る窓:** 下の「forward の TOCTOU」を参照（閉じていない）
- 試験（注入 clock）: 期限切れ・revoke・新 term が古い in-flight request を拒否・古い nonce の返事・再起動（新 boot）は権限なし・solo は明示の no-successor の時だけ・operator 不在は期限切れ。実 op（client の set / delete が op handler から storage へ）で、期限後の旧 master が拒否し storage に届かないこと

**role と partition（今回）:** 各入口は書く前に自分が何かを宣言する（`entry::admit_master(partition)` / `entry::admit_replica(partition, tag)`）。宣言しない entry は engine ON で拒否（fail closed）。grant・期限・serial・floor は partition ごと（`_apply_rw` と `_mutex` だけが node で 1 つ）。
- **MASTER-WRITE**（この partition の master として書く）: その partition の有効な grant が要る。他 partition の grant・grant なし・partition 不明（-1）は拒否。`pre_proxy_write` が `proxy_request_continue` を返した理由（自分が master か、prepare map の master か）から partition を決める（`cluster::write_role`）
- **REPLICA-APPLY**（replica としての適用: proxy / forward / identified change、snapshot relay）: master grant は要らない。変更が持つ権威（`wa=partition:term:gen`。master が forward 時に admission した term / generation を載せる）を検査する。拒否: token なし・不正・別 partition・その partition の floor（この node が知る最新の権威。operator が `authority_set_floor` で渡す、grant の適用、より新しい token の変更の受理で上がる）より古い・この node 自身がその partition の有効な master grant を持つ。floor の引き上げは apply 区間を drain する（admission 後に止まった旧 term の変更は、新 term の変更の後に apply できない）。floor より上の grant は旧 grant を無効にする（降格した master の master-write は拒否）
- **INTERNAL**: reaper / lazy expiry delete / flush_all / snapshot push（master に着いたもの）は**この node の partition の MASTER-WRITE**（表の前の決定のまま。以前は node 単位だった）。orphan purge: partition の master ならその partition の grant が要る。それ以外の role では fence のみ（purge 対象は自 partition の外の key で、複製もされず client ACK もない、という分類。**以前は node 単位の grant を要求していた入口の role 別の緩和であり、レビューで判断を要する**）

**mutation 入口の表（review-safe-eviction §4.3 の列挙）:**

| 入口 | 分類 | admission | apply 点 | forward 直前 | ACK 直前 |
|---|---|---|---|---|---|
| client set / add / replace / append / prepend / cas / touch / gat（`op_set` 系） | MASTER-WRITE | 配線済み（partition 別） | 配線済み | 配線済み | 配線済み |
| client incr / decr（`op_incr`） | MASTER-WRITE | 配線済み | 配線済み | 配線済み | 配線済み |
| client delete（`op_delete`） | MASTER-WRITE | 配線済み | 配線済み | 配線済み | 配線済み |
| 他ノードから master への proxy write（pre-proxy 転送） | MASTER-WRITE | 配線済み | 配線済み | 配線済み | 配線済み |
| master から replica への forward（proxied / identified change） | REPLICA-APPLY | 配線済み（token の検査。incr / set / delete が `wa=` を運ぶ） | 配線済み（identified の apply 前後も） | 配線済み | 配線済み（identified の早期 return の ACK も `ack_ok()`） |
| cross-cluster の受信 write | MASTER-WRITE（foreign mark は client write と同じに routing される） | 配線済み（同じ op） | 配線済み | 配線済み | 配線済み |
| flush_all | MASTER-WRITE（replica は従来どおり拒否） | 配線済み | 配線済み（truncate の前後） | なし（forward しない） | 配線済み |
| snapshot push 受信（master に着いたもの） | MASTER-WRITE | 配線済み | 未（files / WAL の受け入れに apply 区間なし） | なし | 未 |
| snapshot push の relay hop（slave） | REPLICA-APPLY（`wa=` を relay 送信側が載せる） | 配線済み | 未 | なし | 未 |
| orphan purge | INTERNAL（master のみ grant 要、他 role は fence のみ） | 配線済み | 未 | なし | 未（ACK は管理 op の結果のみ） |
| expire reaper | MASTER-WRITE（chunk 単位） | 配線済み（chunk ごと、partition 別） | 未（chunk の delete は apply 区間の外） | 未 | 対象外（ACK なし） |
| lazy expiry delete（storage_rocksdb） | MASTER-WRITE（partition は `set_write_partition`、master 昇格時に cluster が設定） | 配線済み | 未 | 対象外 | 対象外（ACK なし） |
| restore / dump 受信 | 未確認（fence の列挙にも無い） | 未 | 未 | 未 | 未 |

**forward の TOCTOU（閉じていない。残る窓）:** `still_authorized()` の検査と `cluster::post_proxy_write`（キューへの積み込み）は同じ区間ではなく、既存の lock では 1 区間にできない（`post_proxy_write` は cluster の map lock・thread queue・sync 待ちを取る。それらを `_apply_rw` の中で取ると lock 順序が増え、sync の待ちが apply 区間と権威変更をブロックする）。検査の後・積み込みの前に権威が失効・revoke・term 変更されると、**その時点では正当に適用済みの変更が、失効後に replica へ届きうる**。結果: replica 側には token の検査（旧 term は floor で拒否）があり、floor が上がっていれば replica は拒否する。floor がまだ上がっていない replica には届く。client への ACK は `ack_ok()` で拒否される。これは「ACK した値が replica で失われない」ことを守るが、ACK していない値が replica に出ることは防がない。pre-proxy（他の master への転送）には検査を足していない（このノードの権威を使わない経路）。**この窓は閉じたと主張しない。**

**prepare map（partition 数変更中）:** prepare master への forward は master-write として扱われ（grant が要る）、preparing master は grant を持たないため engine ON では拒否される。token の partition 番号（旧 map）と prepare 側の番号も一致しない。partition 数の変更中は engine を ON にできない（未対応として残す）。

**未配線・未実施（C' 完了とは言わない）:**
1. 上表の「未」の全て（snapshot push・orphan purge・reaper・lazy expiry の apply 区間 / ACK、restore / dump）
2. **role / partition 対応は flared 内のみ（今回）:** operator が floor（`authority_set_floor`）を replica に渡す経路、token を持たない旧 build の master との混在、prepare map 中の扱い（上記）は未
3. operator 側: grant の発行・更新・revoke・membership の永続化（`kjob/flare-cprime` の terminal CAS との接続）、request の送信、flared の stats / 管理 op による観測
4. 実行時 E2E（C' の二重 write 0）
5. 単一 node 内の複数 partition（grant は 1 partition のみ）、壁時計・ドリフト・VM 停止の影響

## 13. C' の結線（write authority を operator の昇格経路につなぐ。integ/cprime。既定 OFF、フラグでのみ有効）

§12.2 / §12.5 / §12.6 / §12.7 の方式を、次の具体的な規則で実装する。§12 が決めている詳細（要求起点の期限、nonce、約束の束縛、terminal CAS、S1〜S7）はそのまま従う。ここは**そこで未決だった点**と結線だけを書く。数値（ttl / renew / margin）は設定値で、本番の既定値は持たない。

**フラグ（全部 OFF が既定）。** flared: `write-authority-enabled`（bool）、`write-authority-margin-ms`、`write-authority-max-ttl-ms`（受け付ける約束の ttl の上限。再起動後の静止時間 = max-ttl + margin）。有効なのに margin / max-ttl が 0 なら起動時に拒否。operator: 環境変数 `FLARE_WRITE_AUTHORITY_TTL_MS` / `_RENEW_MS` / `_MARGIN_MS`（TTL が未設定または 0 なら operator 側の C' 経路は全部無効）。**全ノードが同時に切り替える**（混在は未対応: 旧 build の master は `wa=` を運ばず、有効な replica は token の無い変更を拒否する。ローリングでの有効化はしない）。

**決めたこと（§12 の未決の判断）。**
1. 時計の持ち主: intent の `deadline` は **operator leader の時計**（`ClockId` = operator, 起動ごとの boot）。deadline を過ぎた commit は拒否され、その intent は leader が cancel する。successor の自己 cancel（store 経由の timer cancel）は**実装しない**: flared は store に届かない。**代償:** prepare の後に operator が消えると、replica は新しい leader が intent を引き継ぐまで PREPARING のままで、約束を出さないので master は ttl の後に write を止める（S1 の代償。operator 単独故障が write を止めるのは、prepare 中に限る）。
2. membership: partition ごとに `{term, generation, master, successors}`。operator が ConfigMap `{cr}-authority-p{N}` に CAS（resourceVersion）で永続化する。successors = ノードマップで Active の slave。master 変更で term+1、successors 集合の変更で generation+1。**進行中の（terminal でない、または commit 済みで未昇格の）intent がある partition の membership は変えない**（solo や縮小で旧 master の権限を戻さない）。solo = successors が空。
3. master の権限は successor の約束から: master は operator の `authority members` を受け、`renew` 間隔ごとに **全 successor** に `authority promise` を送る（送信点 q を自分の CLOCK_BOOTTIME で記録、同じ nonce）。全員が PROMISED を返した時だけ grant（期限 = q + ttl）。1 つでも欠けたら更新しない（期限は延びない）。solo は operator の `authority solo`（明示）の時だけ期限なし。
4. replica の約束: FOLLOWING の間だけ。受理条件 = engine ON、この node がその partition の slave、floor が設定済みで **term が floor の term と等しい**（generation は floor に含めない: operator は floor を (term, 0) で渡す。successor 集合の変更で generation が動いても、master の forward / 更新を間で拒否しないため）、ttl ≤ max-ttl。**約束の終わり = 受信時刻 + ttl + margin を記録してから**返事を送る。
5. 昇格の gate（flared、最後の砦）: slave から master へ変わる時、engine ON なら、その partition の intent が COMMITTED で、約束の終わり・起動後の静止時間（boot + max-ttl + margin）がともに自分の時計で過ぎている時だけ通す。通らなければ既存の promotion refusal の latch に入る（reads / writes を拒否）。proxy から master（新規 partition の最初の master）は対象外。
6. operator の駆動（commit 点 = `commitChecked`）: 既存の copy を昇格するすべての pass（計画 drain、failover）で、フラグ ON なら、intent 作成 → successor に `authority prepare`（PREPARING。更新を止める）→ prepared 確認 → successor が `promotable_in_ms` を報告し終えるまで待つ → terminal CAS で commit → `authority commit`（flared に伝える）→ 昇格（ノードマップの commit）。各 pass は 1 歩ずつ進み、完了しない pass は昇格を commit しない（次の pass が続ける）。cancel は同じ terminal CAS（leader の cancel）の後に `authority cancel` を送る。**Unknown（store 不達・record 破損・返事なし）では cancel も commit もしない。** 旧 leader は record の fence で拒否される。
7. floor / term: 昇格後の最初の pass で membership の term が +1 される（intent が committed の partition の master 変更だけがこれを起こせる）。operator は到達できる全 replica に `authority floor p term gen` を先に送り、その後に新 master へ `authority solo` / `authority members` を送る。replica は floor 未設定なら**変更を拒否する**（最初の token を受け入れない。operator が floor を渡してから受ける）。
8. partition 数の変更（prepare map）中は engine を ON にしない: `partition-count-change` の pass では authority の push を止め、flared は prepare map の master 宛 forward を engine ON のとき拒否する（既存）。
9. flared の再起動: grant / floor / 約束 / membership は永続化しない（tmpfs 前提）。再起動した master は operator が membership を再送するまで write を拒否する。再起動した replica は静止時間の間は昇格を受けない。**operator が不在の間に master が再起動すると、operator の復帰まで write は止まる**（権威ある membership を持たずに solo を名乗らない、という選択の代償）。

**止まる条件（可用性）。** (a) master と全 successor の約束が切れる経路 → ttl 後に master は write を止める（C'）。(b) prepare 中の operator 不在 → master は ttl 後に停止（上記 1）。(c) 再起動した master と operator 不在の重なり（上記 9）。operator だけが落ちている間（prepare なし）、master と successor がつながっていれば write は続く。

### 13.1 実装（integ/cprime）と、閉じた flared の穴

**flared。** `write_promise`（replica の約束・昇格 gate・master の membership）、`op_authority`（`authority promise|members|solo|floor|prepare|commit|cancel|status`）、`handler_authority`（master の要求ラウンド。要求ごとに送信点を自分の CLOCK_BOOTTIME で取り、全 successor に同じ nonce で送る）、`cluster::_shift_node_role` の昇格 gate（slave → master のみ。proxy → master は対象外）。master が降格したら membership と grant を破棄する（`note_role`）。

**前回の未配線の入口（§12.6 の表の「未」）を閉じた:**
| 入口 | 今回の配線 |
|---|---|
| snapshot push 受信（master に着いたもの）/ relay hop | swap と WAL tail の各 batch を apply 区間で行い、STORED の前に `ack_ok()`。権威が切れていれば swap せず、STORED を返さない |
| orphan purge | master なら key ごとに apply 区間（1 key の delete の間だけ drain を待たせる）、結果の前に `ack_ok()`。他 role は fence のみ（従来の分類のまま） |
| expire reaper | chunk ごとに apply 区間で reap、forward の前に `still_authorized()` |
| lazy expiry delete | **admission のみ（意図的）**: slot lock の中で走るので `_apply_rw` を取れない（lock 順序）。消すのは既に期限切れで読み手に見えない key で、client の見える状態を変えない。旧 master が権限を失った後に 1 件遅れて消しても、見える結果は変わらない |
| restore / dump 受信 | 分類: **INTERNAL-pull**（replica が master の WAL / dump を引く再構築。forward ではなく `wa=` を持たず、client に ACK しない）。gate しない。旧 master が権限を失った後は新しい write を受けないので、引かれるのはそれ以前の内容 |
| pre-proxy | `pre_proxy_write` の判定は `cluster::write_role`（自分が master か、prepare map の master か）で partition を決めてから master-write の admission（配線済み。他 master への転送は受けた側の admission） |

**replica の最初の token**: floor が未設定の replica は変更を**拒否**する（最初の token を受け入れない）。operator が floor を渡してから受ける（`authority floor`）。再起動した replica は operator が floor を再送するまで forward を受けない（欠けた分は WAL follow が埋める）。

**partition 数の変更（prepare map）**: engine ON の間は未対応。operator は CR の partitions とマップの partition 数が違う pass では何も push せず（ログに明記）、flared は prepare master 宛の forward を master-write として admission する（grant がないので拒否）。**対応していないことを明示して拒否する**。

**混在 build**: 全ノードが同時に切り替える。engine ON の replica は `wa=` を持たない変更を拒否するので、旧 build の master と混在させない。ローリングでの有効化はしない（flared を全部再起動して設定を入れる）。

**代償として残るもの（再掲）**: (1) master と全 successor の約束が切れる経路では master は ttl 後に write を止める。(2) 死んだ successor が membership にいる間（operator が外すまで）master は止まる: successors は「Active で Ready で terminating でない slave」なので、計画 drain では先に外れる。突然死では operator の検出 + 1 pass の間止まる。(3) prepare 中の operator 不在。(4) operator 不在の間に master が再起動した場合。(5) async 複製のため、旧 master が権限内で ACK し replica に届いていない write は昇格後に失われうる（§12.4-3、変わらない）。(6) forward の TOCTOU（§12.6）は閉じていない。

**counterexamples found while wiring (each pinned in `test_write_promise` / `test_write_authority` / `WriteAuthorityChecks`):**
1. *A generation change refused the master's own forwards.* The replica's floor was ordered by (term, generation), and the operator gave it the record's generation: a membership change (generation + 1, pushed to the replica first) made the replica refuse the forwards and renewals the master still sent at the old generation — acknowledged writes not replicated, and the promise refused. Now the floor fences by TERM only (the operator gives (term, 0), a replica admits any generation of the current term and refuses an older term); a late forward of an older generation is applied (`test_a_generation_change_does_not_refuse_the_masters_forwards`).
2. *An unlimited solo grant outlived a membership change.* A master that held the solo grant and then got a successor kept the unlimited grant, so promoting the successor would not have ended its authority. `members` for a newer (term, generation) revokes the older solo grant before anything else (`test_a_solo_master_keeps_serving_and_leaving_solo_ends_the_unlimited_grant`), and the operator promotes only when the master confirmed the record (`acked`).
3. *A deposed master kept asking for promises and kept its grant.* `note_role(demoted)` now drops its membership and revokes its grant (`test_a_demoted_master_loses_its_membership_and_its_grant`).
4. *A restarted successor forgot its promises.* Quiet time after its own start = max-ttl + margin (`test_a_restarted_replica_forgets_its_promises_but_waits_the_quiet_time`).
5. *A delayed reply must not extend the master.* Deadline = send point + ttl; a reply after it, an old and a duplicate nonce are refused (`test_a_delayed_reply_does_not_extend_the_master_and_an_old_nonce_is_refused`).
6. *The membership shrinking while an intent is open would hand the old master its authority back.* `Members.next` never changes the successor set while an intent is pending or committed and unpromoted, and a master change without a committed intent keeps the old record (the new master gets no grant) — `tNext`.
7. *A role-based dual-write inference cannot judge the engine* (the isolated master keeps its role for the whole cut): C' is judged on the acknowledgements (`partVerdictWa`), and an unclassified acknowledgement can only make the check stricter.
8. *A client-path precondition that needs an ACK after the cut cannot hold with the engine on* (the isolated master stops acknowledging after its grant ran out): with the engine on the old master's own answer (ack or its refusal) proves the client path is open.

### 13.2 E2E（kind）で走らせる suite（authority ON。ここでは実行していない。ホストの CI で実行）

数値はすべてテストの選択: ttl 6 s / renew 2 s / flared margin 5 s / prepare 窓 120 s。flared は `write-authority-enabled = true`（+ margin / max-ttl）、operator は `FLARE_WRITE_AUTHORITY_{TTL,RENEW,MARGIN,PREPARE_TIMEOUT}_MS`。

| suite | 何を示す（示さない） |
|---|---|
| `node-ops-drain-wa` | A / A': 計画 drain が intent 経由で昇格し、ACK 済みの write が新 master と再構築した replica にある |
| `node-ops-hold-wa` | #3 / D: 遅れた replica のときの保留（intent は作られない） |
| `node-ops-stop-wa` | B / B': worker 停止。successor の約束が切れた後に intent 経由で昇格 |
| `node-ops-partition-wa` | C / C': C' は ACK の時刻で判定（旧 master の最後の ACK が、新 master が ACK し得る最初の時刻より前）。昇格しない / 新 master が ACK しない = NOT VERIFIED（緑にしない）。注入が成立しない = PRECONDITION NOT MET |
| `failover-wa` | 既存 failover suite（2 partition、P0 の master Pod を kill）に authority を ON |
| `write-authority-operator-absent` | operator を 0 にして 60 s（ttl の 10 倍）write が全部 ACK され、grant が最後まで有効 |
| `write-authority-solo` | 1 copy の partition が solo grant で書き続け、operator 不在でも止まらない |

実行コマンドは `flare_e2e --filter <suite>`（1 suite ずつ。`node-ops-*` は multi-node kind、他は single-node）。
