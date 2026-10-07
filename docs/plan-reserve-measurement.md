# rebuildReserveBytes の実測計画（移設先の隔離環境）

状態：**計画（未実行）**。実行前に「1. 実行先」をユーザーが確定・承認する。
決定（2026-10-07）：測定は、作り直す移設先クラスタを Web 未接続の検証環境として
使う。投入元と現行サービスは触らない。最初は生成データ。実データの初期投入とは
分ける。tmpfs の差の内訳を確認するまで reserve は未決。

## 1. 実行先（実行前に確定する。空欄のままでは実行しない）

| 項目 | 値 |
|---|---|
| kube context | （ユーザーが指定） |
| namespace（測定専用、新規） | （ユーザーが指定。既存のものは使わない） |
| 破棄対象 | その namespace 内で試験が作るものだけ：FlareCluster `measure`、StatefulSet `measure-nodes`、Deployment `flare-operator`、Service／ConfigMap／Lease／PVC（`data-measure-nodes-*`）、debug pod、ClusterRoleBinding `flare-operator-<namespace>`（クラスタスコープはこれ 1 つ） |
| 破棄しないもの | 投入元クラスタ、現行サービス、他の namespace、CRD、ClusterRole `flare-operator` |
| 前提（クラスタスコープ、既存のものを使う） | CRD（FlareCluster ほか）と ClusterRole `flare-operator` がこのブランチの chart 版で入っていること。入っていなければ導入は別手順で承認を得る |
| イメージ | このブランチから作ったイメージを、移設先が pull できるレジストリに置く（公開先・タグは別途承認）。`FLARE_E2E_MEASURE_FLARED_IMAGE`／`FLARE_E2E_MEASURE_OPERATOR_IMAGE` で指定 |
| Web 接続 | なし（クライアントに提供しない、Service を外部公開しない） |

## 2. 生成データ（pf-dev 相当）

pf-dev の既知の値：15.85M キー、データ約 7.3 GB（blob 2.69 GB）、更新約 300 件/s
（2026-09／10 の記録）。値サイズの分布は、pf-dev の `stats`（curr_items、bytes、
blob の量）を**読み取りのみ**で取得して決める（pf-dev は変更しない。取得自体も
実行前に承認を得る）。

| 環境変数 | 意味 | 案 |
|---|---|---|
| `FLARE_E2E_MEASURE_KEYS` / `_VALUE_BYTES` | 小さい値の件数・大きさ | 15.8M / 約 300 B（分布で調整） |
| `FLARE_E2E_MEASURE_LARGE_KEYS` / `_LARGE_VALUE_BYTES` | blob になる値（4 KB 以上） | blob 2.69 GB 相当 |
| `FLARE_E2E_MEASURE_RATE` | 再構築中の更新 / 秒 | 300（ピークも 1 回） |
| `FLARE_E2E_MEASURE_CHUNK` | 1 接続あたりのキー数 | 20000 |
| `FLARE_E2E_MEASURE_TMPFS` / `_MEMORY` | tmpfs の場合とその上限 | pf-dev と同じ（tmpfs 6–8 Gi） |

tmpfs と PVC の両方で測る。

## 3. 何を測るか（両側、同じ時刻、種類を明示）

試験 `copy-retention-measure` は、replica の flared を SIGTERM で再起動して
（emptyDir／PVC は残る＝旧コピーの隣に staging を作る最悪ケース）、更新負荷の
下で staged 再構築させ、次を記録する。

- flared の統計（再構築・送出の窓ごとのピーク）：data dir の大きさ（論理）、
  cgroup の `memory.current`、最小の空き（`rebuild_space_available`）。
- 2 秒ごとのサンプル（**両 pod を同じ周期で**、各行に時刻）：
  - `rss`：flared の VmRSS
  - `cgroup_current`：flared コンテナの cgroup の `memory.current`
  - `working_set`：`memory.current - inactive_file`
  - `shmem`：その cgroup に計上された共有メモリ（tmpfs のページはここに出る）
  - `data_logical`：`du --apparent-size`（論理サイズ）
  - `data_allocated`：`du -B1`（実割当）
  - `df`：ファイルシステムの使用量／サイズ
- `/data` の mount（tmpfs か、サイズ）と、flared が属する cgroup（`/proc/self/cgroup`）。

## 4. 値を決める前に確認すること（ユーザー指示）

1. 比較しているメモリが RSS／working set／cgroup 使用量のどれか（サンプルで区別）。
2. ディスク量が論理サイズか実割当量か（`data_logical` と `data_allocated`）。
3. tmpfs の mount と、実際に容量制限を受ける cgroup の対応（tmpfs のページが
   flared コンテナの cgroup の `shmem` に出るか、pod の cgroup か）。
4. 両側で時刻をそろえた測定か（同じ周期のサンプル）。

CI の規模の結果（tmpfs 3 Gi で受け手の `memory.current` 0.88 GB に対し tmpfs の
データ 2.4 GB）だけでは、tmpfs がメモリ上限の外とは結論しない。

## 5. 判定

reserve の候補 = 受け手の増分のうち新しいコピー以外の部分（WAL catch-up、
compaction、一時ファイル）のピーク ＋ tmpfs ではメモリ計上の確認結果に基づく分
＋ 余裕。測定結果と根拠を記録し、値はユーザーが決める。10/12 までに pf-dev 相当で
測れなければ、実データの初期投入は延期する。
