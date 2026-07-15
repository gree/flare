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

## この システムの危険はどこにあるか(レビューの焦点)

1. **master が2つになる**(split-brain): 書き込みが分岐し、静かに壊れる
2. **空のノードが master になる**: パーティションのデータが「即死」ではなく
   「静かに空として提供される」— 最も発見が遅れる壊れ方
3. **復旧処理そのものがデータを消す**: 再構築・truncate・merge は
   すべて「治すために壊しうる」操作
4. **大規模障害時の過剰反応**: AZ 落ちで全パーティションを一斉に
   再割当てすると、障害が復旧を上回る速度で拡大する

以下の性質はこの4つに1対1で対応する。

## 性質 → 実コード → 証明 → E2E の対応表

| # | 性質(平文) | 守っている実コード | 機械検証(定理) | 実クラスタ E2E |
|---|---|---|---|---|
| P1 | **master は各パーティション高々1** | 割当は「master 不在のパーティション」にのみ行う `findPartitionNeedingMaster` / 並行書き込みの合流点で重複 master を修復する `mergeClusterState`+`demoteDuplicateMasters`(いずれも `StateMachine/K8sReconciler.lean`, `Reconciler.lean` — 本番がそのまま実行する関数) | **一般帰納**(任意の状態・任意のステップ列・無制限長): `stepGlobal_preserves_atMostOne` / `stepMany_preserves_atMostOne`(`GeneralSafety.lean`)。合流点単体でも任意入力で `mergeClusterState_atMostOneMaster` | failover / pvc-data-survival / circuit-breaker。**全開発期間・全 CI で二重 master の観測ゼロ** |
| P2 | **failover はデータを持つ「生きた」replica を昇格する**(空の再作成 pod や、pod が消えた幽霊エントリを master にしない) | `handleFailoverWithPromotionSingleKey`(demote と同 tick で slave 昇格、role/partition の防御ガード付き)+ pod 生存リストで候補を絞る `findActiveSlaveForPartition` | failover: `scenario3_dead_node_not_master`、ゾンビ: `scenario4_zombie_not_master`、幽霊: `scenario5_ghost_not_promoted`(いずれも `VerifiedSafety.lean`、モデルは本番と同一関数を呼ぶ) | data-survival-failover(**100キーを値まで完全一致で読み戻す**。欠損は即 fail)/ pvc-data-survival(master+slave 同時死)/ terminating-pod-handling |
| P3 | **Active な master はデータを保持している**(「空 master」の禁止 — P1 だけではこれを禁止できない点が本 PR 最大の学び) | 再構築前 truncate の三重ゲート(rocksdb かつ **slave ロール** かつ **ソース生存確認済み**、`handler_reconstruction.cc`)+ Active 指定の役割変更は再構築しない(`cluster.cc`) | データ保全不変条件 `activeMasterHoldsData` が failover/ゾンビ/幽霊の全シナリオで成立(`data_*_ok`)。truncate ゲートは仕様として定理化: `truncate_gate_preserves_last_copy` と **`ungated_truncate_destroys_last_copy`(ゲートを外す変更はモデルのコンパイルが通らない)** | pvc-data-survival / backup-restore(flush_all 全損→checkpoint から全キー復元) |
| P4 | **新しい事実は古い計算に上書きされない**(pod の再登録を、古いスナップショットから計算した結果が「幽霊」として蘇生させない) | 登録エポック `FlareNode.regEpoch` + 「新しいエポック側が丸ごと勝つ」merge(`mergeNodeEntry`) | `ghost_not_resurrected`(バグをそのまま符号化した回帰定理)/ 併せて「登録は merge で消えない」`mergeClusterState_preserves_keys`(任意入力) | pvc-data-survival(この修正が green 化の決め手)/ operator-restart(operator 死→状態 reload の同一性) |
| P5 | **過半死では何もしないのが正しい**(circuit breaker)、かつ**復旧は自動再開** | `circuitBreakerDecision`(閾値 50%)+ terminal 状態 `EmergencyPaused` | 閾値以上で必ずトリップ `circuitBreakerDecision_trips` / 未満では絶対にトリップしない `_no_trip` / **トリップ中 FSM は状態も要求も一切出さない** `emergencyPaused_inert` | circuit-breaker suite(持続的過半死→トリップ→**15秒2点サンプルでチャーンなし**→容量復帰→operator 再起動なしで回復) |

E2E は計 22 スイート 125 テスト(kind 上の実 StatefulSet + 実 flared)。上記のほか、
スケール操作(out/in)、Blue/Green 移行、WAL 増分同期、設定伝播、バックアップ/リストア
を網羅する。全スイートに「失敗時に operator/flared のログを teardown 前に採取する」
診断フックが入っており、flake は再現ログ付きで届く。

## 形式手法が実際に働いた代表例(4件)

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
`ghost_not_resurrected` がバグそのものを回帰定理として封印している。

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

## Q. なぜ「証明したもの」と「動くもの」が同一だと言えるのか

この資料が受けるべき最初の疑いなので、機構・確認手順・限界を明示する。

**機構**: operator は Lean で書かれており、**定理が言及する関数と本番バイナリが
実行する関数が、同一ファイル内の同一定義**である。TLA+ などと違い
「スペックを書き、別言語で実装し、目視で対応させる」翻訳工程が存在しない。
例(P1 の合流点):

- 定理: `mergeClusterState_atMostOneMaster`(`K8sReconciler.lean`)は
  `FlareOperator.K8sReconciler.mergeClusterState` について述べる
- 本番: reconcile ループの commit(`Main.lean` の `commitClusterState`)は
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
| C++ flared(複製・再構築の実体) | **同一ではない** — 手書きモデル(`FlaredNode.lean`)による近似 | E2E + 単体テスト。実例: Active-shift の意味論乖離はここで起きた(前節4件目) |

## よくある質問(先回り)

**Q. `decide` によるシナリオ定理は、ただのユニットテストでは?**
その通り、具体シナリオの decide 定理の証拠能力はテストと同等である。差は
2点: (1) 実装の定義に直結しているため、実装変更で**必ず**再実行される
(テストは呼び忘れうる)。(2) それとは別に、入力に依存しない一般定理
(`GeneralSafety.lean` の任意状態・任意ステップ列、merge の任意入力)が
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
