# flareのスペック

1, 全てのサーバーがproxy:違うパーティションのデータやslaveにきた書き込みなどが適切なサーバーに転送
2, データにはバージョンがついている。すでに大きいバージョンがついているなら小さいバージョンのデータは書き込めない。異常系で同一パーティションのマスターが二ついる場合があったら不整合がでることは許容する。k8sのAPIに接続できないなどネットワーク障害での異常系を想定している。
3, master / slave型
4, 自動failoverの機能: masterがおちるとslaveがmasterになる。昇格先は operator から疎通できる slave のうち、最も新しいデータを持つもの（10/27）。「最も新しい」= 最後の master に追従していた slave の中で、その master から最後に適用した位置（sequence）が最大のもの。別の履歴の位置は比べられないので、追従していた slave が残っていないときだけ別の履歴の slave を候補にする（10/27 ユーザー確認）。
5, 正常系では無停止/ダウンタイムなしで動作、ユーザーはいつでも読み書きできる
6, 正常系のサーバー入れ替えや増設も無停止/ダウンタイムなし
7, 異常系で突然ノードが落ちた場合はその分のデータはきえても問題ない、非同期レプリケーションで大丈夫
8, master/slaveの非同期レプリケーションで読み出しのディレイ（レプリケーション遅延）はネットワーク的に近ければ0.5ms以下
9, rocksdbをバックエンドだが、tmpfsまたはssd常にディスクを構築（storage is tmpfs or SSD.）
10, rocksdbのスナップショットとWALでS3に逐次バックアップ：バックアップ遅延は5分程度. Disater Recoveryを想定。
11, slaveの構築はmasterのデータから構築：rocksdbのスナップショットとWAL、従来モードでキーとバリューのフルダンプによる構築も可能
12, operatorからflareのnodeにアクセスできない場合はdown判定し、対象がmasterならslaveをmasterに昇格、slaveなら別のslaveの再構築をする。operatorがflareノードのステートを遷移させる能力があり、それが疎通できないのであれば該当サーバーは直ちにdownにしてproxyにし、slaveがいれば直ちにmasterにするようにnode_mapをなるはやでおくる。operatorから到達できない・ヘルスチェックの判定はEC2でのflare indexサーバーと同等の処理を行う。（リトライ回数とウェイト時間の組み合わせ）ただし operator が**全てのノードに**届かないときは、k8s API や環境のネットワークの問題とみなし、down・昇格などを**何もしない**（alert だけ）。ネットワークが怪しい・壊れているときは動かさない方がよい（10/31 ユーザー決定）。
13, operatorとk8sのAPIが正常に動作していたら異常系で同一パーティションのマスターが複数台になったとしても、一方をdownにし、ただちに復帰できなければならない。仮にoperatorやLBから到達できない自称masterのようなもの（operatorがnode_mapで配ったmasterと違うサーバー）はユーザーからの接続があれば問題があるが、基本的にはLBや他のnode（正常なnode_mapをもっているサーバー）からアクセスだけ有効でそこに先ほどの自称masterは排除される。不整合は許容しない: 全ノードに同じ node_map を配っているので、operator が配った版と違う版で master を名乗るノード（重複した master）は検出して down 扱いにする（10/31 ユーザー決定）。

## SAF 系（SAF-01〜11、SAF-10 C′）の要点

出典: `docs/SAFETY-TODO.md`、`docs/SAF10-RELEASE-CHECKLIST.md`、`docs/design-authoritative-history.md`、`docs/STPA-node-state.md`（rc68 にもある）、`docs/design-node-operations-2026-10-19.md`（SAF-10 ブランチ `safety/saf-10-restore-provenance` のみ）。本番の系列（rc67/rc68）に入っていないものは「SAF-10 ブランチのみ」と書く。

### 正常系

- node_map の配布は、確定した状態から、現 leader だけが送る。旧 leader の古い状態は送らない（SAF-01）。
- node_map の版は単調に増える。各ノードが適用した版を読み、届いていなければ再送する（SAF-09）。
- master から slave への転送が落ちたら、その slave は down にして作り直す（10/27 方針）。今の replica repair も実際は「slave を proxy に降格 → master から作り直し（WAL の差分か全体 dump）」で、件数はその判断に使っているだけ。作り直しの途中に入った書き込みを取りこぼす競合がある（rolling で 75 件欠落、flare-bug-slave-catchup-map-race）ので、これは直す。continuous WAL replication（下）を ON にできれば転送の取りこぼしを WAL が埋めるので、作り直し自体が減る（ON にする。ただし最初のリリースでは見送り、次のリリースで入れる。10/31 ユーザー決定）。
- slave は master の WAL を継続的に追いかけられる（continuous WAL replication）。転送と WAL のどちらで届いた変更も、同じ適用規則（変更元の sequence が大きいときだけ適用、削除は tombstone）で適用する（SAF-10b〜d。最初のリリースは OFF、次のリリースで ON）。
- 昇格させるのは、operator から疎通でき、最も新しいデータを持つ slave（10/27 方針。4 を参照）。今の実装（SAF-03 の promotion by reason: 追いついた証拠・履歴の一致を要求）はこれより厳密で、条件を満たす slave が無いと master なしで待つ（rc68 の drain 試験で 10 分止まった原因の一つ）。簡単な規則に寄せる。ただし作り直し途中・空のコピーは昇格させない。
- コピーは、代わりのコピーができるまで消さない（copy retention / copy protection）。
- 計画的な退避（drain）は webhook で一度止め、準備してから通す（eviction guard。SAF-10 ブランチのみ、既定 OFF）。現在の方式は書き込みを約 46 秒止めてエラーを返すので、5・6 を満たさない。順序付きハンドオーバーに置き換える予定（flare-lossless-switch-paths）。
- クラスタ間の移設（別の K8s クラスタへ flare クラスタごとデータを移す機能。FlareMigration / cluster replication。例: AWS から pf-dev への移行で使った）は、per-key の seed と、切替までの書き込み停止で行う。ノードの入れ替え（6）とは別の機能。重要な機能なので残す（10/31 ユーザー決定）。

### 異常系

- 観測できない・読めない値は Unknown として扱い、「健全」「空」とみなさない。Pod の同一性（UID・boot id・copy id）を確かめてから削除や昇格をする（SAF-04・08）。
- 300 s は昇格の一律な遅延ではなく、master の data-plane 障害を確認した後、通常の規則で昇格先を選べない場合にだけ使う最終手段の猶予とする。通常規則で選べる、到達可能・非空・作り直し中でない slave があれば、300 s 待たずに最も新しいコピーへ切り替える（4・12）。通常規則で選べる候補がない間は master なしとして alert を出し、復旧を再評価する。猶予は障害確認後の最初の「候補なし」判定から数える。operator/API の読み取り失敗や状態不明だけでは master 障害の確認にも猶予の開始にもならない。
- 猶予の満了時にも通常候補がなければ、到達可能で、非空かつ作り直し中でないと確認できるコピーのうち最も新しいものだけを最終手段として昇格し、`PROMOTION NOT LOSS-FREE` を記録する（7 の範囲）。この場合はデータ損失の可能性を受け入れる。空・作り直し中・quarantined・観測不能／状態不明のコピーは、満了後も昇格させない。それ以外に昇格可能なコピーがなければ master なしを維持し、CRITICAL alert と手動復旧を要求する。元 master の復帰だけを理由に、通常候補が既にある切替を300 s保留しない。
- 同時に落ちたノードが多すぎるときは、circuit breaker で自動の昇格・削除を止める（SAF-11）。
- leader が lease を更新できなくなったら、自分で leader をやめて終了する（lease guard、fail closed。SAF-10 ブランチのみ）。
- 起動時に node_map が失われていたら、承認なしに新規クラスタとして作り直さない（SAF-09）。
- 履歴の比較は 4 の候補選択規則に従い、追従していた slave を厳密な履歴判定だけで候補から外さない。追従コピーが残っていない場合は、別履歴のコピーも 4 と上記 300 s の最終手段規則に従って扱い、履歴が異なることを理由に無期限に master なしにはしない。ただし、空・作り直し中・quarantined・観測不能／状態不明のコピーは昇格させない。実際に「追従していた slave が別の履歴と判定されて昇格できない」問題が起きた（同じ Pod 名の master が戻ったとき、残った slave が古い履歴のまま再構築されず、drain で後継がいなくなった。flare-bug-same-key-repromotion）。バックアップからの復元は、データがバックアップにしか残っていない場合の話なので、その場合は戻すしかない（戻したコピーを master にできなければならない。10/31 ユーザー決定）。採用の手続きを要求する仕組み（restore provenance）は SAF-10 ブランチのみで、SAF-10 の見直しは行わない（10/31）。
- WAL の batch は CRC で検査し、壊れた batch を受けた slave は自分で作り直す。
- master のデータが空になったら、データを持つ slave に切り替える（空 master の自己修復）。
- operator から到達できないノードは down にして proxy にし、master なら slave を昇格する（12）。今の rc68 は Ready なら failover しない（`Main.lean` 3383、到達性 probe は alert のみ）ので、12 に合わせて変える。昇格先は operator から疎通できる slave だけ（疎通できない slave は failover 先にしない）。masterをdownさせる場合は昇格先がある場合だけ。operator が全てのノードに届かないときは何もしない（API・ネットワークの問題）。※10/31 午前の判断 A（到達性は alert のみ）は、この決定で置き換え。
- C′（管理系だけが切れ、client は旧 master に届く）では、旧 master と新 master が同時に書き込みを受け得る。write authority（ttl 付きの約束で旧 master を止める仕組み）は実装済みだが OFF で、本番には入れない判断（2 で不整合を許容）。13 の「operator が健全なときに master の重複を検出して解消する」仕組みは、まだ無い。不整合は許容しないので実装する: 配った node_map と違う版で master を名乗るノードを検出して down 扱いにする（10/31）。
