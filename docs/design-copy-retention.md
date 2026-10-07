# コピー保持・staging・切替・容量管理の設計（R3-D 残件 + R7）

状態：**設計 第3版（2026-10-07、2 回目のレビュー指摘と命名を反映。実装中）**。
§12 の 1〜4、§8、7（stats による数え上げを除く）を実装（macOS 単体試験済み、
Linux CI・E2E は結果待ち）。5（quarantine）・6（承認 CR）は未実装。
§10 の例外（数えるが保留しない）：TCP の再登録で自分の partition に戻る
メンバー、master の再構築、flared の起動時 catch-up。初期構築は例外にしない。

固定された方針（ユーザー、2026-10-07）：

- 通常は staging にコピーし、検証してから切り替える。
- 旧コピーを保持する容量がなければ、自動で破棄せず停止して通知する。
- 旧コピーの破棄は、対象のコピーを特定した明示的な承認による別の操作にする。

第2版の決定事項（ユーザー回答）：

- 項目数は整合性の合否に使わない（診断用のみ）。
- 容量マージンは根拠なく固定しない。設定可能にし、R7 の負荷試験で決める。
  算定できなければ停止する。
- 旧コピーの削除条件：対象 attempt の検証、正しい source への binding、
  replica 自身の Active をすべて確認したときだけ。
- 承認の窓口：Kubernetes では RBAC のある CR を第一段階とする。対象 Pod UID・
  copy-id・要求 ID を指定し、一回限りで消費して結果を記録する。汎用の公開
  管理コマンドは後回し。
- 同時数：再構築は partition ごとに 1、クラスタ全体でも 1。snapshot serve は
  source ごとに 1。再起動後も実行中の処理を数える。
- quarantine：自動削除なし。1 世代まで。次の隔離が必要なら停止する。バイト
  予算は容量設定に含める。

## 1. 配置（同じファイルシステム上の兄弟ディレクトリ）

```
data_dir/
  flare.rocksdb/            live（今と同じ）
  staging-<attempt-id>/     受信中の新コピー
  retained-<attempt-id>/    切替後の旧コピー
  quarantine-<copy-id>/     隔離した壊れたコピー（1 世代まで）
  switch.intent             切替の intent（§4）
  quarantine.marker         隔離の印（§6）
  snapshot.serve.<req-id>/  送り手の checkpoint（§5）
```

- rename するのはコピーのディレクトリだけ。`data_dir` 自体は rename しない。
- 起動時と各操作の前に、`data_dir` と各ディレクトリの `st_dev` が同じこと
  （rename が原子的であること）を確認する。違えば停止する。

## 2. コピーの identity

- 各コピーは**永続的な一意 ID**と**世代**を持つ。ID は作成時に 1 回だけ発行
  する uuid。世代は、そのコピーの中身が置き換わるたびに単調に増える数。
  どちらもコピーの中（予約キー）と、ディレクトリ内の `COPY_ID` ファイルに
  持つ。
- **copy-id = ID + 世代**。件数・バイト数からは作らない（同じ件数・サイズで
  中身が変わり得る）。
- **二重保存の順序と不一致**：予約キーと `COPY_ID` は、どちらも中身を変える
  **前に**新しい値に更新する（truncate の世代更新も、データを消す前に行う）。
  途中で落ちても、古い世代が変わった中身を指すことはない。予約キーと
  `COPY_ID` が一致しないコピーは、通常の健全なコピーとして扱わない：
  - stats `rocksdb_copy_identity_consistent=0`。
  - 承認は受け付けない。
  - read の binding をしない。
  - 昇格候補と修復元から外す。
  - 検証済みの再構築（新しいコピー）で解消する。
- staging のコピーは新しい ID で作る。切替後の live は staging の ID のまま。

## 3. コピーの整合性（検証。件数は使わない）

### 3.1 snapshot

- 取得境界：送り手の checkpoint の sequence（`cp_seq`）と、その時点の
  source epoch。どちらも checkpoint と同じ一貫した時点で取る（既存）。
- 連続性：swap の前に、staging に対して `cp_seq` から source の現在位置まで、
  **epoch に結び付いた** WAL catch-up を行う（同じ epoch を名乗らない応答、
  欠番、purge 済みなら失敗）。

### 3.2 full dump（コピー中の変更を取りこぼさない、途中状態を公開しない）

「適用は冪等」だけでは足りない。dump に新しい値が含まれていても、古い WAL を
再生している途中では一時的に巻き戻る。そこで以下を**すべて**条件にする。

1. dump の開始前に、source の位置 `L0` と epoch `E` を記録する。
2. dump を staging に書く。
3. dump の完了後に、追いつく**目標位置 `L1`** を source から確定する
   （epoch `E` のまま）。
4. `L0` の次から `L1` まで、同じ履歴（epoch `E`）の WAL を**欠落なく順序どおり**
   staging に適用する。
5. その間、staging は read・昇格・修復元に**一切使わない**。staging は live の
   外にあり、map にも binding にも現れない。§4 の切替より前には誰も読めない。
6. 次のどれかなら検証失敗とし、staging を捨てて旧コピーを保持する：WAL の
   purge（欠番）、epoch の変更、不完全な dump（完了マーカーなし）、source の
   identity の不一致、`L1` まで到達できない。
7. **期間中に変更されなかったキーを取りこぼさない**こと：op_dump の server が
   単一の iterator で全キーを走査し、完了マーカーまで送ることを前提にし、
   試験で確かめる（§11）。

（任意の改善：dump の server が自分の iterator の snapshot sequence `Ld` を
送れば、`Ld` から再生でき、巻き戻りが起きない。旧版 source は送らないので、
基本は `L0` から再生する。）

**旧版 source**（epoch に結び付いた WAL catch-up を提供しない）：承認による
免除はしない。**外側で書き込みを止め、それを維持する手順**でだけ扱う。
- `L0 == L1`（同じ epoch）は「書き込み停止の確認」ではない。同一履歴の
  シーケンスがすべての変更を捉えるという前提のもとで、「その観測区間に変更が
  なかった」根拠になるだけ。その後も止まっている保証ではない。
- 手順：書き込みを外側で止める（運用手順） → dump → `L0 == L1` を確認する →
  コピーを検証する → 切り替える → そこで初めて書き込み停止を解除する。停止は
  検証と切替が終わるまで解除しない。
- 位置を読めない source（LSN を提供しない）では、観測区間の根拠もないので
  停止する。
- リリースノートと運用手順に記載する。

### 3.3 切替前の最終確認

- 保護規則（`copy_protection.h`）を、切替の直前にもう一度評価する。
- 件数は記録するが、合否には使わない。

## 4. 切替（クラッシュに耐える、状態から復旧を判断する）

### 4.1 手順と同期順序

0. **新コピーを永続化する**：staging の DB を flush して閉じ、WAL を sync し、
   staging ディレクトリの全ファイルとディレクトリ自体を fsync する。
   `staging-<id>/COPY_ID` を書いて fsync する。ここまで終わってから 1 に進む。
1. intent を一時ファイルに書いて fsync し、`switch.intent` に rename し、
   `data_dir` を fsync する（PREPARED）。
2. live の DB を閉じ、`flare.rocksdb` を `retained-<id>` に rename し、
   `data_dir` を fsync する。
3. `staging-<id>` を `flare.rocksdb` に rename し、`data_dir` を fsync する。
4. 新しい live を開き、`COPY_ID` が intent の新コピーと一致することを確認する。
5. intent を削除し、`data_dir` を fsync する。

intent のフェーズ欄は診断用。**復旧はフェーズに頼らず、実在するディレクトリと
copy-id から判断する**（intent の更新前に落ちても判断できるように）。

### 4.2 起動時の復旧（intent を先に解決し、staging の掃除は最後）

intent があるとき、intent の旧 ID を O、新 ID を N とする。L・R・S は
`flare.rocksdb`・`retained-<id>`・`staging-<id>` の実在とその `COPY_ID`：

| L | R | S | 意味 | 処置 |
|---|---|---|---|---|
| O | なし | N | 手順 2 の前 | 切り替えていない。intent を削除（attempt は中止） |
| なし | O | N | 手順 2 の後、3 の前 | ロールバック：R を L に戻す → intent を削除 |
| N | O | なし | 手順 3 の後 | 前進：L を開いて N を確認 → intent を削除 |
| N | なし | なし | retained が消えている | 停止して通知（CRITICAL。retained は §8 の前に消えてはならない） |
| その他（O も N も見つからない、ID の重複・不一致など） | | | 不整合 | 停止して通知（CRITICAL）。何も消さない |

- 各 rename は原子的で、`data_dir` の fsync の後に永続化される。どの rename の
  前後で落ちても、上の表のどれかの状態になる。
- intent の解決が終わってから、intent が参照していない `staging-*` を削除する。

## 5. 送り手（snapshot serve、R7）

- 要求ごとに分離する：`snapshot.serve.<req-id>`。固定パスを作り直さない。
- 同時数は source ごとに 1。超えた要求は `busy` で返し、client は待つ。
- 後始末：転送の完了・失敗・切断で、その要求の領域を消す。起動時には
  `snapshot.serve.*` をすべて消す（そのプロセスの転送は残っていない）。
- 実行中の serve は永続的な marker で数える（再起動しても数え直せる）。

## 6. quarantine

- **順序**：
  1. `quarantine.marker` を書いて fsync する。内容は対象のコピーの copy-id と
     時刻。
  2. 壊れた DB を `quarantine-<copy-id>` に rename し、`data_dir` を fsync する。
  3. 新しい空の DB を作る。

  marker は空 DB を作る**前から**永続している。どこで落ちても、次の起動で
  marker があれば、live は「隔離後の空コピー」として扱う。
- **隔離後の空コピーの扱い**（marker がある間）：
  - stats `rocksdb_quarantined=1`。
  - read はしない（R3 の binding は none）。
  - operator は昇格候補から外し、修復元（source 判定）では Unknown として
    defer する。
  - marker を消すのは、検証済みの再構築（§3）が完了し、§8 と同じ条件
    （正しい source への binding と自身の Active）を満たしたとき。
- **上限**：`quarantine-*` は 1 世代まで。既にあるのに次の隔離が必要なら、
  隔離せず停止して通知する。自動削除はしない。隔離領域の削除は §7 の承認で
  行う。
- 隔離は `is_corrupted` を検出したときだけ。

## 7. 明示的な承認（Kubernetes：CR `FlareCopyDiscardApproval`）

- RBAC で作成権限を絞る。承認できるのは**特定のコピーの破棄だけ**。整合性の
  保証は免除しない（旧版 source の in-place 再構築は対象外：§3.2）。
- spec：
  - `clusterUID`、`podUID`、`copyId`、`requestId`
  - `operation`：`discard-retained` ／ `discard-before-copy`（容量不足のとき、
    特定のコピーを先に捨てる） ／ `discard-quarantine`
  - `expiresAt`（有効期限）
- status：`phase`（Accepted／Running／Completed／Rejected）、理由、対象の
  attempt、各時刻。
- operator は clusterUID・Pod UID・copy-id が**今**一致し、期限内のときだけ
  flared に渡す。flared も、保存中のコピーの copy-id と一致するときだけ実行する。
- **一回限りの実行を flared 側でも永続的に重複排除する**：
  1. 実行前に `requestId` を data_dir の承認記録へ "started" として書いて
     fsync する。
  2. 実行する。
  3. "done" と結果を書いて fsync する。

  同じ `requestId` が再び届いたら、記録を見て応答し、再実行しない。"started"
  だけが残っていれば、対象のコピーが実在するかで実行済みを判断する（破棄済みなら
  done にする）。これで、実行後・status 保存前に落ちても再実行しない。
- コピーが変われば（世代が増えれば）、承認は失効する。承認は容量と運用の判断
  だけを上書きし、保護規則（安全）は上書きしない。

## 8. 旧コピー（retained）の削除条件

以下をすべて確認したときだけ自動で削除できる。それ以外は承認（§7）が要る。

1. 対象 attempt の検証（§3）が成功した。
2. 新しい live の copy-id が、その attempt の staging のもの。
3. read source の binding が、その attempt の source（lineage と epoch）で
   eligible。
4. replica **自身の** map で Active（operator の view だけでは不可）。

## 9. 容量（二重計上しない、監視する）

- `statvfs` の空きには、既存の retained・quarantine・staging の使用量が
  **すでに反映されている**。そこからもう一度引かない。
- 判定：これから増える量 ＋ 予約分 ≤ 使える空き。
  - 増える量：staging の見込み（source の `rocksdb_data_bytes`、R7 で計測して
    係数を決める）＋ WAL catch-up の見込み。
  - 予約分：CR の `spec.rocksdb.rebuildReserveBytes`（compaction・WAL・
    quarantine の予算）。値は R7 の負荷試験で決める（未決）。
  - **未設定なら再構築は止まる**（`rebuild_blocked=reserve_unset`）。source の量を
    読めないときも止まる。リリースノートに明記する（既存のクラスタは、設定する
    まで再構築しない）。
- hard link：checkpoint と snapshot は SST を共有し得る。共有分は増える量に
  入れない。数えるのは新たに書かれるファイルだけ。
- tmpfs：ファイルシステムの空きと、cgroup のメモリの余裕（上限 − 現在の使用量。
  tmpfs のページとプロセスのメモリの両方を含む）の小さい方を使う。
- **コピー中も監視する**：上限を超える前に転送を止め、staging を消し、旧コピーを
  保持して停止・通知する。
- 停止したら `stats rebuild_blocked=<理由>`、CRITICAL ログ、メトリクス、
  operator のアラート（`FlareRebuildBlockedNoSpace`）で知らせる。

## 10. operator

- 同時数：再構築は partition ごとに 1、クラスタ全体でも 1。**repair ledger だけ
  では数えない**：初期構築、再起動後の再登録（rejoin）、re-seat、ledger に
  載らない flared 自身の再構築も含める必要がある。
  - 数える対象：map で Slave/Prepare のノード、および stats で
    `reconstruction_current_state=running` を報告するノード。どちらも operator の
    再起動後に読み直せる（map は永続、stats は各ノードのもの）。
  - 制御点：ノードを Slave/Prepare に割り当てるすべての経路（autoAssign、rejoin、
    re-seat、zone swap、初期構築）で、上限に達していれば Proxy のまま待たせる。
    flared は map が Prepare を指示したときにだけ再構築を始めるので、割り当ての
    制御で flared 自身の再構築も数えられる（例外を見つけたら列挙する）。
  - 初期構築（空クラスタ）は上限の対象外にするかを、実装時に明記する（データが
    ない段階の直列化は不要）。
- 隔離中・再構築停止中のノードを昇格候補から外す。アラートを出す。
- release／re-seat 時の再確認は維持する（実装済み）。

## 11. 試験（停止点で順序を固定する）

1. full dump の staging：dump 中に**更新・削除・再作成・期限切れ**を続け、
   `L1` までの再生の後に全キー・値（期限を含む）が source と一致する。dump 中に
   変更されなかったキーも全部ある。purge・epoch の変更・不完全な dump では
   切り替えず、旧コピーを保持する。staging が途中で read・昇格・修復元に
   使われない。
2. 切替の**各 rename の前後・intent 更新の前後**での kill → 起動時に、実在する
   ディレクトリと copy-id から §4.2 の表のとおりに復旧する。staging の掃除は
   intent の解決の後。
3. 容量不足（開始時とコピー中）→ 停止・通知・旧コピー保持。copy-id と
   Pod UID が一致する承認だけが一度だけ通る。コピーが変わった後の承認は失効。
4. snapshot の同時要求（2 replica）→ source ごとに 1 に直列化され、互いを
   壊さない。serve の後始末と、起動時の掃除。
5. snapshot の swap と先行破棄の境界で source の変更／Unknown → 旧コピーを
   保持する。
6. quarantine：marker の後・rename の後・空 DB 作成の後の各点で kill しても、
   次の起動で空コピーが健全扱いされない。1 世代の上限で停止する。
7. 混在バージョン：旧版 source ではオンライン再構築をせず、停止・通知する。
   書き込み停止を確認できたとき（`L0 == L1`）だけ進む。承認では進まない。
9. 承認の重複排除：実行後・status 保存前に落としても、同じ `requestId` で
   再実行しない。期限切れ・copy-id の不一致・クラスタ／Pod UID の不一致は拒否。
8. 旧コピーの削除：§8 の 4 条件のどれかが欠けたら削除しない。

## 12. 実装の順序

1. コピーの identity（ID・世代、`COPY_ID`、stats）。
2. 切替と起動時の復旧（§4、純粋な判定表を単体試験）。
3. full dump と snapshot の staging 化、`L0`／`L1` の再生と検証（§3）。
4. 容量（§9、`rebuildReserveBytes`、コピー中の監視）。
5. quarantine（§6）。
6. 承認 CR と flared の重複排除（§7）。
7. snapshot serve の分離と同時数（§5）、operator の同時数（§10）。
