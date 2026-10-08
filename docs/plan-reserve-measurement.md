# rebuildReserveBytes の実測計画（移設先の隔離環境）

状態：**計画（未実行）**。実行前に「1. 実行先」をユーザーが確定・承認する。
決定（2026-10-07）：測定は、作り直す移設先クラスタを Web 未接続の検証環境として
使う。投入元と現行サービスは触らない。最初は生成データ。実データの初期投入とは
分ける。tmpfs の差の内訳を確認するまで reserve は未決。

## 1. 実行先（候補。2026-10-08 に変更なしの確認で作成。承認前は何も作らない）

確認したこと（すべて読み取りのみ）：context 一覧、namespace、CRD、ClusterRole、
StorageClass、ノードの割当・使用量、pf-dev の Pod 配置と構成、イメージ。

| 項目 | 候補 | 確認結果 |
|---|---|---|
| kube context | `gree-tc-tc-wg-dev-cluster-01`（既存の開発クラスタ） | pf-dev（namespace `pf-dev`）が同じクラスタにある |
| namespace | 新規 `flare-reserve-test` | 存在しない（NotFound） |
| CRD | 既存のまま使う（変更しない） | `flareclusters`／`flaremigrations` あり。`flarecopydiscardapprovals` はない（測定に不要）。既存 CRD に `rebuildReserveBytes` がないので、reserve は CR ではなく extra.conf で渡す |
| RBAC | **namespace 内の RoleBinding** で既存 ClusterRole `flare-pf-dev-flare-operator` を参照（ClusterRole は変更しない。ClusterRoleBinding は作らない＝クラスタ全体の権限を与えない） | `flare-operator` という ClusterRole はない。nodes の読み取り権限がないので operator はゾーン配置を無効にして動く（警告ログのみ） |
| イメージ | このブランチの測定時点の commit から `publish-images` で専用タグを発行し、**digest で固定**（ghcr.io/gree への発行は承認が必要） | pf-dev は ghcr.io/gree の rc56／rc65 を pull している |
| ストレージ | tmpfs（`emptyDir medium: Memory`、pf-dev と同じ方式）。PVC 版は cbs（`Delete`）を 2×20Gi | pf-dev は tmpfs 8Gi・limit 8Gi・request 7Gi |
| 配置 | pf-dev の Pod と同じノードに置かない（podAntiAffinity）。プール `np-q50mfoyg`（32 CPU／56 GiB） | 下記の容量の問題あり |

**必要な容量と影響（pf-dev 相当、tmpfs）**

- データ約 7.3 GB。staged 再構築では受け手に旧コピーと新コピーが並ぶので、受け手の
  上限は約 2×7.3 GB＋予約分＝**18 Gi 程度**。送り手 8 Gi。合計の request は約
  27 GiB（operator・debug を含む）。
- pf-dev と同じ 8 Gi の形では staged 再構築は no_space で止まる（それ自体が結果の
  一つ。pf-dev の形では旧コピー保持の再構築ができない）。
- pf-dev の Pod がないノードは `10.163.224.7`（pf-dev の operator と他 namespace の
  Pod）。memory request は既に約 66%（40/60 GB）で、空きは約 20 GB。**27 GiB は
  入らない**。`10.163.224.6` は autoscaler の削除対象（taint あり）。
- 選択肢：
  - A（推奨）：プールに 1 ノード増える（autoscaler）ことを許容し、pf-dev の Pod と
    別ノードに置く。pf-dev のノードには何も置かない。費用は測定時間分。
  - B：`10.163.224.7` の空き（約 20 GB）に収まる半分の規模（約 3.7 GB）。pf-dev
    相当ではない（外挿になる）。
  - C：eklet（サーバーレスの仮想ノード）。pf-dev のノードから完全に分離できるが、
    cgroup・tmpfs の計上が pf-dev と同じとは限らず、tmpfs の差の確認には向かない。
- pf-dev への負荷：データ Pod は別ノード、通信は namespace 内のみ、測定の operator
  は自分の namespace だけを見る（RoleBinding も namespace 内）。A では pf-dev の
  ノードの CPU・メモリ・ネットワークを使わない。

**作成するオブジェクト（すべて `flare-reserve-test` 内）**：Namespace、
ServiceAccount `flare-operator`、RoleBinding（→ 既存 ClusterRole）、ConfigMap
`measure-config`／`measure-node-map`、Lease、Deployment／Service `flare-operator`、
Service `measure-nodes`／`measure-0`、StatefulSet `measure-nodes`（Pod 2）、
FlareCluster `measure`、debug Pod、PVC（PVC 版のみ）。

**削除**：測定後に namespace `flare-reserve-test` を削除（中のオブジェクトと PVC が
消える）。**削除しないもの**：CRD、ClusterRole、他の namespace、pf-dev。

**value-size 分布**：`stats` で取れるのは件数（curr_items）と SST の合計
（`bytes` = rocksdb.total-sst-files-size）だけで、分布は取れない。Pod 内の `du`
（SST と blob ファイルの合計）で、inline と blob（4 KB 以上の値）の比率は分かる。
分布そのものは全件走査が要るので、行わない（必要なら別途相談）。生成データは
「件数・平均の大きさ・blob の比率」を合わせた 2 種類の大きさの混合にする。
pf-dev への読み取り（`stats` と `du` のみ、変更なし）も承認後に行う。

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
