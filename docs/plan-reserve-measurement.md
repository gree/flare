# rebuildReserveBytes の実測計画（移設先の隔離環境）

状態：**A を承認済み（2026-10-08、ユーザー）。レビュー指摘3点（配置、8Gi 条件、8時間上限）を反映した計画の承認待ち。クラスタには何も作っていない。**
承認範囲：追加ノード最大1台、対象は `flare-reserve-test` のみ、専用タグの GHCR 公開と digest 固定、pf-dev の read-only stats／対象ディレクトリの du。全キー走査と既存環境の変更はしない。
決定（2026-10-07）：測定は、作り直す移設先クラスタを Web 未接続の検証環境として
使う。投入元と現行サービスは触らない。最初は生成データ。実データの初期投入とは
分ける。tmpfs の差の内訳を確認するまで reserve は未決。


## 0. 作成前の提示（2026-10-08、読み取りのみで確認）

**pf-dev の read-only 読み取り（2026-10-08T03:23Z、stats と du のみ）**

| | nodes-0（master） | nodes-1 |
|---|---|---|
| curr_items | 15,855,220 | 15,858,010 |
| SST（`bytes`＝SST 合計） | 2.73 GB（54 files） | 2.77 GB（59 files） |
| blob files | 2.81 GB（192 files） | 0.62 GB（58 files） |
| 論理（du --apparent） / 実割当（du -B1） | 5.71 / 5.79 GB | 3.51 / 3.55 GB |
| tmpfs（8 GiB） 使用 | 68% | 42% |

- 件数は同じでも blob の量が 4.5 倍違う（2.81 vs 0.62 GB）。nodes-1 は 2 日前に再構築されている。差の一部は GC されていない古い値と**推定**するが、2 台の比較だけでは差のすべてを garbage とは断定できない（内訳は未確認）。
- **容量の見積もりには実使用量を使う**（送り手のコピーの大きさ＝du の実割当、nodes-0 で 5.79 GB）。staged 再構築の容量判定も送り手のコピーの大きさを使う。
- 推定（近似条件としてのみ記録。値サイズの分布ではない）：SST 平均 ≈ 2.75 GB / 15.86M ≈ 173 B／キー、blob 0.62–2.81 GB。
- 以前の記録（7.3 GB）は古い。

**生成データ**：15.86M キー × 約 170 B ＋ blob 用の 4 KB 値 約 150k 件（≈ 0.62 GB）。加えて、送り手の実使用量を nodes-0 と同程度（約 5.8 GB）にするため、大きい値を上書きする段階を入れる（再現するのは実使用量であり、nodes-0 の内訳ではない）。

**配置（実行のたびに、作成の直前に読み取りで決める）**

1. 除外するノード＝pf-dev のデータ Pod（`flare-pf-dev-nodes-*`）がいるノード（現在 `10.163.224.11`、`10.163.96.29`）。実行直前に読み直す。
2. 既存の適格ノード：プール `np-q50mfoyg` の中で、除外ノード以外、Ready、`allocatable − requests` が測定の requests（下表）以上のもの。現在の候補は `10.163.224.6`（32 vCPU／64 GB、autoscaler の削除候補、pf-dev の Pod なし）。あれば `FLARE_E2E_MEASURE_NODE` でそのノードに固定する。
3. 既存の適格ノードがない（`.6` が消えた等）：固定はせず、`FLARE_E2E_MEASURE_NODE_POOL`（プール）と `FLARE_E2E_MEASURE_AVOID_NODES`（除外ノード）の必須の nodeAffinity で作る。flared の 2 Pod は必須の podAffinity で同じノードに置くので、autoscaler が追加するのは **最大 1 台**（2 Pod 目は 1 Pod 目と同じノードにしか置けない）。追加されたノードの名前・プール・pf-dev の Pod がないことを確認して記録する。
4. 置かれたノードが条件を満たさなければ、測定を始めずに namespace を削除する。

**上限（namespace の ResourceQuota と LimitRange）**

| 項目 | 上限 |
|---|---|
| requests.cpu / limits.cpu | 10 / 10 |
| requests.memory / limits.memory | 36Gi / 36Gi（16Gi 評価：flared 2 × 16Gi、request＝limit、operator 1Gi、debug） |
| requests.storage / PVC 数 | 40Gi / 2（PVC 版のみ。cbs） |
| pods | 6 |
| ネットワーク | flared の `reconstruction-bwlimit`／`rocksdb-snapshot-bwlimit` = 32768 KB/s。両 Pod が同じノードなので、再構築の通信はノードの NIC を通らない。外向きはイメージ pull と API のみ |

**実行の流れ（各回の後に namespace を削除）。2 つの評価を分ける**

| 評価 | tmpfs | コンテナの memory limit | request | 目的 |
|---|---|---|---|---|
| R1：16Gi 評価 | 16Gi | 16Gi | 16Gi | 再構築の両側のピークと reserve の候補を測る（pf-dev とは違う条件） |
| R2：pf-dev の 8Gi 構成 | 8Gi | **8Gi** | 7Gi（pf-dev と同じ） | pf-dev と同じ条件で何が起きるか（no_space で止まるか、OOM か）を確認する |
| R3：PVC 20Gi | なし（PVC） | 16Gi | 16Gi | ディスクの場合の比較 |

R1 の成功は 8Gi 構成の承認ではない。R2 の結果を見て、移設先のメモリを増やすか、保存方式を変えるかを決める。

**時間と費用の上限（両方を適用）**：測定開始（最初のオブジェクト作成）から**最大 8 時間**、かつ終了期限まで。追加ノードの稼働時間は最大 **8 時間**（SA5.8XLARGE64 の従量課金。単価は公開ページで確認できず、**コンソールでの確認が必要**）。CBS 2×20Gi を数時間。`.6` が削除候補のまま残っているのを使う場合、その分だけ autoscaler による削除が遅れる。

**終了期限**：**2026-10-09 18:00 JST**、または開始から 8 時間の早い方。終わっていなくても、その時点で止めて削除する。

**終了手順**
1. 削除の前にログを退避する（試験の出力、サンプル、各 Pod の flared と operator のログ、`kubectl get events`、配置したノード名）→ `docs/reports/` に保存。
2. namespace `flare-reserve-test` を削除する。
3. 確認：namespace が消えた、PVC と（その PVC に紐づいた）PV が残っていない、CBS ディスクが残っていない（PV の volumeHandle で確認）、測定の Pod がどのノードにも残っていない（＝測定がノードを引き留めていない）。
4. 共有ノードを手動で削除する操作はしない。ノードの縮小は autoscaler に任せ、測定の Pod がなくなったことだけを確認して記録する。

**pf-dev への追加の読み取り（承認待ち、未実施）**：cgroup のメモリ使用量・上限・内訳（memory.current／memory.max／memory.stat）、flared の RSS、`/data` の mount と `df`。短時間・低頻度（例：数回）、設定変更・全キー走査・flush・compaction はしない。

**削除対象**：namespace `flare-reserve-test`（中の Deployment、StatefulSet、Service、ConfigMap、Lease、RoleBinding、ServiceAccount、ResourceQuota、LimitRange、FlareCluster `measure`、debug Pod、PVC）。CRD、ClusterRole、他の namespace、pf-dev には触らない。GHCR の専用タグは測定記録のため残す（削除する場合は指示による）。

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
