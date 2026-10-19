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
