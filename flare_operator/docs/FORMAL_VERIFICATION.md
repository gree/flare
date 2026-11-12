# flare operator の形式検証：証明したこと、していないこと

最終更新: 2026-11-12（feature/lossless-switch 3c3b88fd 時点）

- 定理の全一覧: [formal-verification-theorems.csv](formal-verification-theorems.csv)（183 行。ファイル、行、定理名、分類、何を保証するか、本番の operator がその関数を使っているか、注意点）
- `flare_operator/FlareOperator` 以下に `sorry` と `axiom` はない。
- 証明のモジュールは既定の `lean_lib FlareOperator`（`StateMachine` 以下を含む）に入っている。`lake build` のたびに検査され、定理が成り立たなくなればビルドが失敗する。

この文書は、証明の**範囲と境界**を正しく示すためのものである。形式検証の対象は operator の**純粋な判断関数**の一部であり、operator 全体ではない。flared（C++）、kubectl と API サーバー、ネットワークは信頼している前提であり、証明の外にある。

## 1. 数で見る現状

| 分類 | 本数 | 意味 |
|---|---|---|
| 一般定理 | 78 | 任意の状態や入力で成り立つ（∀） |
| 具体例 | 42 | 固定の 1 シナリオを計算して確かめたもの（`decide` / `rfl` / `native_decide`）。そのシナリオでしか言えない |
| 補助補題 | 35 | 他の定理の証明に使う部品 |
| 抽象モデル | 28 | 本番では実行しないモデル（`GlobalState` / `stepGlobal`、時相論理）についての定理 |

| 本番経路 | 本数 | 意味 |
|---|---|---|
| 本番経路 | 110 | 定理の対象の関数を、動いている operator が呼ぶ |
| モデルのみ | 68 | 証明やテストだけが使う関数、またはモデル |
| 一部 | 5 | 本番も同じ関数を使うが、証明していない引数や上書きがある（下の 2.3 参照） |

`native_decide` を使う定理が 8 本ある（ノードマップの往復 2 本と、ゾーン修復 6 本）。これらは Lean のカーネルではなく、コンパイラの計算を信頼している。

## 2. 証明したこと

### 2.1 本番の判断についての一般定理（もっとも価値が高い）

| 性質 | 主な定理 | 限界 |
|---|---|---|
| **commit するノードマップでは、各パーティションの master は高々 1 つ** | `demoteDuplicateMasters_atMostOne`, `mergeClusterState_atMostOneMaster`（K8sReconciler.lean） | 任意の入力で成り立ち、`mergeClusterState` を通る commit（`commitChecked` / `commitClusterState`）はすべて対象になる。残す master はリスト順で決まり、データの新しさは見ない。**merge を通らない書き込み（3.1）は対象外** |
| 1 回の操作で master は増えない（増えても 1 つまで）（CLE） | `reconcileStep_cle`（TCP の node add など）、`registerFreshNode_cle`、`autoAssign_cle`、`assignProxiesPure_cle`、`handleFailover*_cle`、`handleDrain*_cle`、`applyZoneRepairSwap_cle` | TCP の経路は merge を通らずに live 状態へ書くので、ここでは `reconcileStep_cle` が根拠になる |
| reconcile の 1 パスは必ず終わる | `flareReconcileStep_decreases_measure`、`measure_zero_is_terminal`、`terminal_absorption` | `flareReconcileCore` を直接扱う。活性として実際に意味があるのはこの 3 本 |
| サーキットブレーカー | `circuitBreakerDecision_*`（7 本）、`emergencyPaused_inert`、`recoveryRefill_*` | 発動、不発動、ヒステリシス、手動での保持、停止中に何もしないこと |
| マイグレーション（`migStep`） | `migStep_*`（9 本） | cutover と retire は承認が必要。forward には承認と証拠が必要。後戻りできない地点の後は abort しない。観測（`MigObs`）を作る IO は信頼している |
| トポロジの世代フェンス | `startupVersion_gt_resumed`、`startupGeneration_ge_lease`、`generation_fences` | 新しい leader の version は、永続化済みの値より大きい。「永続化してから送る」は IO 側の約束で、証明していない。カウンタが 2^32 未満であることは仮定 |
| balance の正規化と状態のマージ | `normalizeBalance*`、`mergeClusterState_preserves_keys`、`mergeClusterState_down_survives` など | 正規化で role、partition、キーは変わらない。マージでキーは消えない。Down は Down のまま残る |
| 冗長コピーの破棄 | `RedundantCopy` の 3 本 | 破棄を認める対象は Slave だけで、別ノードに master があり、同じ履歴の Active な Slave がもう 1 つあるときに限る。Facts（stats の値）が正しいことは信頼している |
| TCP イベント | 13 本 | 読み取り専用のイベントは状態を変えない。手動の role 変更と node remove は拒否する |

### 2.2 具体例とモデルの定理

- `VerifiedSafety.lean` の scenario 1〜6 とデータ保持の定理（`data_*`）は、**固定の 4 ノードのクラスタ**を計算して確かめたもの。フェイルオーバー、ゾンビ master、ゴースト、全体の再起動の筋書きが、そのとおりに動くことを示す回帰テストとして役立つ。一般の場合については何も言わない。
- `data_*` は、モデルの「書き込みは Active な slave へ同期的に複製される」という仮定に依存する。**実際の live の複製は非同期の転送**なので、瞬断で書き込みが消えることがある。これは証明されていない。
- `GeneralSafety.lean` / `Safety.lean` の `stepGlobal_*` と `globalSystemSafety` は、逐次モデル `GlobalState` の上の一般定理（任意のステップ列で master は高々 1 つ）である。本番と純粋関数を共有しているが、モデルは昇格を既定の引数で呼び、Handover、NodeMove、ReplicaRepair、IO、並行性を持たない。
- `Invariants.lean` の 3 本の不変量は、遷移関係の定義に結論がすでに含まれていて、それを取り出しているだけである。`handleFailoverPure` 系の 4 本は、証明でしか使わない関数についての定理（本番は `handleFailoverWithPromotion`）。
- `Liveness.lean` は、前提 `clusterSpec` が進行とフェイルオーバーの活性を仮定している。そのため `failoverCompletes_holds` は、仮定を取り出しているだけである。

### 2.3 「一部」の 5 本（本番の呼び方とずれているもの）

| 定理 | ずれ |
|---|---|
| `promoteMasterlessPartition_cle`, `promoteMasterlessPartitions_cle` | 既定の引数（standby、dataBearing、excluded、blocked などがすべて空、hold は false）のときだけ証明している。本番は空でない引数で呼ぶ |
| `breakerUnavailable_ge_dead` | 本番が数えるのは `breakerCountedKeys`（handover 中のノードを除いたもの）で、この定理の対象ではない |
| `no_registration_during_send`, `no_send_during_registration` | 純粋なゲートの性質だけを示す。本番は 20 秒たつと `forceRegistration` でゲートを越える |

## 3. 証明していないこと

安全上重要だが定理がないものを挙げる。単体の検査は `flare_operator/FlareOperatorTests/UnitTests*.lean`（例を並べた `check`）に、E2E は `FlareOperator/E2E/Tests/*.lean` にある。`docs/safety-evidence.json` の 20 個の control（EV-01〜20）は、すべて `verification: unverified` のままである。

| 対象 | 何が証明されていないか | 今の確かめ方 |
|---|---|---|
| 3.1 live 状態への直接の書き込み | 順序付き切替の各段のマップを配る経路（`Operator/Handovers.lean` の `.send`）は、`Handover.apply` の結果を `stateRef` に直接書き、`mergeClusterState` を通らない（後継の昇格を確定する `commitPromote` は merge を通る）。NodeMove と ReplicaRepair の降格、prepare-repair、起動時の ConfigMap の読み込みも直接書く。これらの経路では「master は高々 1 つ」は証明の外にある（STPA H6 / UCA-08） | UnitTestsHandover、E2E NodeOpsSwitch / HistoryContinuation / TerminatingPodHandling |
| 3.2 順序付き切替（Handover / HandoverDrive / HandoverFence） | 3 段のマップの順序、各段の確認、rollback、break-glass を受け付ける条件 | UnitTestsHandover、UnitTestsFence、E2E HistoryContinuation、node-ops-switch-* |
| 3.3 cordon 移設（NodeMove） | 1 Pod ずつ動かすこと、`released` は後戻りしないこと、取消との線形化 | UnitTestsNodeMove、E2E node-ops-switch-tmpfs-cordon-* |
| 3.4 削除と退避のガード（NodeGuard、Rolling、`StatsObservation.deleteGate`） | 強制削除、後継のない master、データを持つ ordinal の scale-down を拒否すること | UnitTestsNodeGuard、UnitTestsRolling、E2E WebhookTls / PvcDataSurvival |
| 3.5 昇格先の選び方 | CLE が言うのは master の「数」だけで、「誰を選ぶか」（データが新しいか、空でないか、R3 で適格か）は証明していない。PromotionEvidence、SourceEligibility、FailoverOrder、AuthoritativeHistory、HistoryContinuation が対象 | UnitTests、E2E FailoverOrder / DataSurvivalFailover / history-tracking |
| 3.6 同期の証拠 | `SyncEvidence.judge`（Prepare から Active へ）、`FollowEvidence.judge` / `classify` | UnitTests、E2E PrepareEvidence / ContinuousReplication* |
| 3.7 ReplicaRepair の台帳 | 書き込みを落とされた replica が、作り直しが終わるまで pending のままであること | UnitTests、E2E ReplicaRepair |
| 3.8 死亡の検出と unhealthy の扱い | `detectDeadNodesPure`、unhealthy な唯一の master を保持すること、後継のない drain で master を保持すること | E2E Failover / TerminatingPodHandling |
| 3.9 lease と leader | `LeaseFence.held` は renew の成功と残り時間からだけ権限を認めること。確認してから送るまでの競合 | UnitTests（LeaseFence）、E2E TopologyAuthority / OperatorRestart |
| 3.10 トポロジの配信と監査 | 配信の順序と、一部のノードにだけ届いた場合 | UnitTests（TopologyObservation）、E2E TopologyAuthority |
| 3.11 `Main.lean` の IO シェル | ループ、効果の実行、再試行、並行するスレッドの割り込み | E2E 全般 |

### 信頼している前提

- **flared（C++）:** version フェンス（新しい map だけを受け付ける）、WAL の連続性と適用、truncate のゲート、stats の値の正しさ。一部は C++ の cutter 試験で確かめている。
- **kubectl と API サーバー:** Lease の意味、UID 前提付きの DELETE、Pod の Ready と存在の観測、ConfigMap への書き込みの成否。
- **ネットワーク:** 配信が届くこと、一部だけに届くこと、遅延（どれもモデル化していない）。
- **Lean コンパイラ:** `native_decide` の 8 本。
- **`IO.Ref.modifyGet` の原子性とスレッドの並行性:** モデルは逐次である。

## 4. 次に証明するとよい候補（リスクを減らす順）

| # | 性質 | 対象 | 理由 | 難しさ |
|---|---|---|---|---|
| 1 | live 状態への**すべての**書き込みで master は高々 1 つ | `Handover.apply` の各段、NodeMove と ReplicaRepair の降格、prepare-repair。または「配るマップは必ず `demoteDuplicateMasters` を通る」 | 3.1。STPA H6 は、今の証明がハザードより狭いと明記している | 中 |
| 2 | `promoteMasterlessPartition(s)_cle` を本番の引数で証明する | 全引数を任意にする | 2.3。今は既定の引数のときだけ成り立つ | 小 |
| 3 | 昇格先は適格なノードだけ | `handleFailoverWithPromotion`、`handleDrainWithPromotion`、`promoteMasterlessPartition` | 除外したノード、R3 で不適格なノード、空と分かっているノードを、通常の昇格では選ばないこと（UCA-07、rc54 で空の master が作られた件） | 中 |
| 4 | 後継のない drain では master を保持する | `handleDrainWithPromotionSingleKey` | SC-08、rc48 の drain guard | 小 |
| 5 | 削除のゲート | `StatsObservation.deleteGate` / `emptyMasterVerdict` | 読めない値を 0 と扱わないこと、条件がすべてそろうまで削除しないこと（SC-05、H5） | 小 |
| 6 | lease による権限 | `LeaseFence.held` | SC-01。レビューで直した箇所 | 小 |
| 7 | 同期の証拠 | `SyncEvidence.judge`、`FollowEvidence.judge` | SC-04、UCA-10/26 | 小〜中 |
| 8 | ReplicaRepair の台帳 | `advanceEntry` / `resolve` | SC-03。瞬断による書き込みの消失を検知できるのはこの台帳だけ | 中 |
| 9 | NodeGuard の拒否条件 | NodeGuard の判定関数 | UCA-13、H5 | 小 |
| 10 | 順序付き切替の段の順序 | Handover の状態機械 | lossless な切替の設計目標。今は E2E だけで確かめている | 大 |

## 5. 確かめ方

```sh
cd flare_operator
lake build FlareOperator          # 証明を含む。sorry があれば警告、定理が崩れればビルドが失敗する
git grep -nE "^\s*(private |protected )?(theorem|lemma) " -- 'FlareOperator/*.lean' 'FlareOperator/**/*.lean' | wc -l   # 183
```

定理を足したり変えたりしたときは、`formal-verification-theorems.csv` の行と、この文書の数を更新する。
