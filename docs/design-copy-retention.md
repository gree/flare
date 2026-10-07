# コピー保持・staging・snapshot・容量管理の設計（R3-D 残件 + R7）

状態：**設計案（レビュー待ち、未実装）**。2026-10-07。

ユーザーが固定した方針（2026-10-07）：

- 通常は staging にコピーし、検証してから切り替える。
- 旧コピーを保持する容量がなければ、自動で破棄せず停止して通知する。
- 旧コピーの破棄は、対象のコピーを特定した明示的な承認による別の操作にする。

## 1. 現状と不足

| 経路 | 現状 | 不足 |
|---|---|---|
| full dump（受け手） | 保護規則を truncate の直前に評価してから truncate し、dump する | dump 中に source が変わると、旧コピーはもうない。staging がない |
| snapshot（受け手） | 受信を staging に置き、swap の直前に保護規則を評価する。拒否なら staging を消して旧コピーを保持する | 容量不足のときは先に旧コピーを捨てる（strict な保護つき）。方針の「停止・通知」になっていない |
| snapshot（送り手、R7） | 固定パス `snapshot.serve.tmp` を作り直すだけで直列化していない | 同時要求が互いの checkpoint を壊す。tmpfs では checkpoint が SST をメモリ上に固定する |
| quarantine | 壊れた DB を `quarantine-<time>-<pid>` に退避し、空で開き直す。退避できなければ停止 | 隔離領域が容量判定に入っていない。隔離後の空 DB の適格性が明示されていない。再起動で隔離を繰り返す可能性 |
| operator | 再構築の同時実行数に上限がない | 一斉再構築で master の負荷・メモリが集中する |

## 2. 受け手（replica の再構築）

### 2.1 staging と検証後の切替（full dump・snapshot 共通）

1. **staging**：試行ごとの領域 `data_dir/staging-<attempt-id>`。
   - full dump は live の DB ではなく、staging 上に開いた別の RocksDB に書く。
     op_dump client の書き込み先を、渡された storage にする。
   - snapshot は既存の staging をそのまま使う。
2. **検証**（すべて満たしたときだけ切り替える）：
   - source の identity（lineage と epoch）が開始時と終了時で同じ（既存の照合）。
   - dump の完了マーカー、または snapshot の END と cursor。
   - staging の項目数が、終了時の source の項目数と一致する。dump は
     point-in-time ではないので、差の許容は ±（dump 中の書き込み数）とし、
     数値は要決定。
   - 保護規則（`copy_protection.h`）を、切替の直前にもう一度評価する。
3. **切替**（2 相、クラッシュに耐える）：
   1. `switch-intent` ファイルを書く（attempt id、旧／新のパス）。
   2. live を `retained-<attempt-id>` に rename する。
   3. staging を live に rename する。
   4. 開き直す。
   5. intent を消す。
4. **旧コピーの扱い**：切替の後も `retained-<attempt-id>` として残し、新しい
   コピーが activation を通る（Active になる）まで保持する。その後に自動で
   消す。消すのは新コピーが検証済みで Active になったときだけ。

### 2.2 容量判定（停止・通知）

- 必要量：source のデータ量（stats に `rocksdb_data_bytes` を追加）に係数を
  掛けたもの。係数は要決定（compaction・WAL の余裕）。
- 利用可能量：statvfs の空きから、retained・quarantine・staging の使用量を引く。
  tmpfs ではメモリ上限の余裕も含める（既存の `rebuild_space_available` を拡張）。
- 足りなければ**停止**する：
  - 旧コピーは保持したまま。ノードは Prepare（read は転送）。
  - `stats rebuild_blocked=insufficient_space`、ログ（CRITICAL）、
    メトリクスで知らせる。
  - operator はこれを読んでアラートを出す（`FlareRebuildBlockedNoSpace`）。

### 2.3 明示的承認による旧コピーの破棄（別の操作）

- 管理コマンド `rebuild_discard_approve <copy-id>`。copy-id は、そのノードの
  incarnation・source epoch・項目数・保存バイト数から作る識別子で、stats に
  表示する。
- flared は copy-id が**現在保存しているコピー**と一致するときだけ受理する。
  承認は一度だけ有効で、コピーが変われば無効になる。
- 受理すると、その再構築は「旧コピーを捨ててから staging する」で進む。
  - 保護規則（strict）は引き続き適用する。
  - 承認は容量の判断だけを上書きし、安全の判断は上書きしない。
- operator 側の窓口（CR の annotation で copy-id を指定するなど）は要決定。

### 2.4 クラッシュからの復旧（起動時）

- `staging-*`：未完成なので削除する（中身は source から取り直せる）。
- `switch-intent` がある：
  - live がなく retained がある → retained を live に戻す（ロールバック）。
  - live が新しい → retained を残したまま、intent を消す。
- `retained-*`：Active への遷移を確認できるまで保持する。起動直後は消さない。

## 3. 送り手（snapshot serve、R7）

- 要求ごとに分離：`snapshot.serve.<request-id>`。固定パスを作り直さない。
- 同時数の上限（既定 1）。上限を超えた要求は `busy` で返し、client は待って
  再試行する。full dump には自動では落とさない。
- 後始末：転送の完了・失敗・切断で、その要求の領域を消す。起動時には
  `snapshot.serve.*` をすべて消す（転送中のものは存在しない）。
- 容量：checkpoint が固定する SST の量を見積もり、容量判定に含める。tmpfs で
  余裕がなければ serve を断る（`busy`）。

## 4. quarantine

- **容量**：`quarantine-*` は容量判定の使用量に入れる。上限（個数・合計
  バイト）を超えるなら、新たな隔離はせず停止して通知する。
- **適格性**：隔離後の空 DB は「健全な空コピー」ではない。
  - stats に `rocksdb_quarantined=1` を出す。検証済みの再構築が完了するまで
    続ける。
  - read：binding は none なので、ローカルでは答えない（既存の R3）。
  - 昇格：operator は `rocksdb_quarantined=1` のノードを昇格候補から外す。
  - 修復元：operator の source 判定は、`rocksdb_quarantined=1` の master を
    Unknown として扱い、defer する。
- **繰り返さない**：隔離は `is_corrupted` の検出時だけ行う。隔離した事実を
  永続的な marker として新しい DB に記録し、同じ起動周期での再隔離をしない。
  再起動のたびに隔離が起きるなら、上限で停止する。

## 5. operator

- 再構築の同時実行数の上限（partition ごとに 1、クラスタ全体で N。N は要決定）。
  上限を超えた要求は保持して待つ。
- アラート：`FlareRebuildBlockedNoSpace`、`FlareQuarantinedCopy`。
- release／re-seat 時の再確認は維持する（実装済み）。

## 6. 試験（停止点で順序を固定する）

1. staging の検証失敗（dump 中に source の履歴を変える）→ 旧コピーを保持し、
   切り替えない。
2. 切替の各相でのクラッシュ（seam で停止して kill）→ 起動時に一貫した状態に
   戻る（ロールバックまたは完了）。
3. 容量不足 → 停止と通知。旧コピーを保持する。copy-id を指定した承認でだけ
   進む。違う copy-id の承認は拒否する。
4. snapshot の同時要求（2 replica）→ 互いを壊さず、上限で直列化される。
5. snapshot の swap と先行破棄の境界で、source の変更／Unknown → 旧コピーを
   保持する（R3-D 残件 2）。
6. quarantine：隔離後のノードが read・昇格・修復元に使われない。隔離を
   繰り返さない。隔離領域が容量判定に入る。
7. 混在バージョン：旧版 source のときは WAL catch-up をせず、保護された
   再構築が完了する。

## 7. 要決定事項（ユーザー判断）

- 検証での項目数の許容（dump は point-in-time ではない）。
- 容量の係数と、tmpfs のメモリの余裕。
- 旧コピー（retained）をいつまで保持するか（Active への遷移まで、とする案）。
- 承認の窓口（flared の管理コマンド、CR の annotation、またはその両方）。
- 再構築の同時実行数の上限 N。
- quarantine の上限（個数・合計バイト）。
