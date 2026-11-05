# 順序付き引き継ぎで履歴を継ぐ（replica を full rebuild しない）— 設計案 第 6 版（＋ 追補 1〜4）

> **追補 4（2026-11-06、追補 3 070e4d6 への reviewer の指摘 P1 2 点）**
>
> 1. **V1' で旧 master に戻すのは、commit が無いことを証明できたときだけ**
>    - 「commit 0」と判定する条件は、`prepared` の**全員**について、新しい完全な stats（END まで揃ったもの）で次がすべて成り立つこと。
>      - binding が保存した値と同じ。
>      - `history_pending` が、この hid の pending を示す（commit も discard もされていない）。
>      - epoch = fromEpoch。
>    - 1 人でも読めない、応答が分からない、binding が違う場合は、「0」とは扱わない（unknown）。
>      - binding の違う Pod は、元のコピーを持たない。ただし commit したかどうかは分からないので、unknown に数える。
>    - **rollback の意図を先に永続化する**
>      - 証明できたら、まず phase `rollingBack`（leaderEpoch 付き）を CAS で書く。その後に、V1' の送信と各 replica への `history discard` を行う。
>      - 再起動・leader の交代の後に `rollingBack` を読んだら、rollback の続きだけを行う。前へは進まない。
>      - 各 replica は V1' を受け取ると、pending を自分で捨てる（A2: map が別の master を示す）。
>    - **unknown が残る場合**
>      - 後継が同じ binding で応答するなら、`promoting` へ進む。後継は H で清浄なので、どの場合でも安全に進める。
>      - 後継も応答しないなら、何も昇格させずに止める。
>        - CRITICAL のログと Event を出し、`status.handovers[].reason` に理由を書く。
>        - 読めるようになったら、上の規則でやり直す。
>        - この間、書き込みは W で待つ。`Tw` を超えた分はエラーになるが、ACK 損失は無い。これは既決の区分 (a)・(b) と同じ扱い。
> 2. **`promoting` で後継に V2 を送った後**
>    - 後継に V2 を送った時点からは、「後継がすでに master かもしれない」として扱う。
>    - そのため、次のどちらかを確かめるまでは、**別の replica を昇格させない。**
>      - (a) 後継が master として適用を終えた。
>      - (b) 後継の process がもう存在しない。
>    - **適用済みの判定**: 後継の binding が保存した値と同じで、`node_map_version ≥ V2`、`own_role = master`、epoch = toEpoch。これで (a) とし、既存の完了条件へ進む（残りに V2 を送る）。
>    - **応答が分からない（timeout、stats が読めない）**
>      - 同じ binding に V2 を再送する（冪等）。適用済みかどうかを読み直す。
>      - Pod の UID が同じ間は、別の replica を昇格させない。
>      - `Th` を超えたら止めて知らせる。止め方と知らせ方は §1 と同じ。
>    - **Pod が消えた、または binding が違う**
>      - 次のどちらかを API で確かめたときだけ、(b) とする。
>        - Pod が NotFound である。
>        - Pod の UID が違う。
>      - 同じ UID のまま boot id が違う場合（container の再起動）は、新しい process が古い map で master にならないとは限らない。
>        - 新しい process は起動時に operator から map を受け取るまで proxy だが、確かめていない。
>        - そのため、この場合は (b) とせず、上の「応答が分からない」と同じに扱う。
>      - (b) の後に限り、追補 2 §3 の「commit 済みの replica を後継に替える」を行う。
>        - その map（V3）は、元の後継の node key を Master にしない（proxy か down）。
>        - 元の後継が新しい Pod で戻ってきても、V3 で proxy になる。
>    - **E2E を足す**
>      - 後継に V2 を送った直後に、後継の Pod を消す。後継が適用する前と後の 2 通り（test seam で適用を遅らせる）。
>        - 確かめること: master は 1 つ以下（`atMostOneMasterPerPartition` と、各 Pod の own_role を時系列で記録）。missing 0。
>      - 後継の stats を読めなくする（ネットワークを切る）→ 別の replica を昇格させず、止まって知らせる。
>      - prepared の 1 人を読めなくした状態で後継を止める → rollback もせず、止まって知らせる。読めるようになったら規則どおりに進む。


> **追補 3（2026-11-06、追補 2 748f5b4 への reviewer の指摘 P1 2 点）**
>
> 1. **phase の書き込みを、送信より先にする**（intent first）。lease と leader epoch で守る。
>    - **書いてから送る**
>      - V2 を送る前に、`committingReplicas`（またはその次の段）を `status.handovers` に CAS で書く。
>      - CAS の成功を確かめた leader だけが、その段の送信をしてよい。
>      - 送信は冪等（同じ map の版）。新しい leader が status から再開して送り直しても、結果は同じになる。
>    - **CAS の期限**: EvictionGuard の admitted と同じ規則にする。
>      - CAS を始める前に、`heldUntil − now ≥ 4 s（kubectl の上限）+ 1 s` を要求する。足りなければ書かない。
>      - CAS は `min(4 s, heldUntil − now − 1 s)` で打ち切る。
>      - CAS の応答の後、`heldUntil > now` と leader epoch が変わっていないことを確かめてから送る。
>    - **leader epoch**
>      - Entry に `leaderEpoch`（書いた leader の lease の世代）を持たせる。
>      - 新しい leader は、まず自分の epoch を CAS で書く（引き継ぎの takeover）。そのうえで続きを行う。
>      - 古い epoch の leader の CAS は resourceVersion で負ける。lease guard で止まった leader は送らない。
>    - **応答が分からない CAS**（timeout など）
>      - 結果を推測しない。その tick では送らない。
>      - 次の tick で status を読み直し、書けていればその段の送信、書けていなければもう一度 CAS、のどちらかを行う。
>      - phase は一方向にしか進まない（`preparing → committingReplicas → promoting`）。読み直した段より前の段の動作はしない。
>    - **期限内に終わらないとき**
>      - `committingReplicas` の期限（`Th` の残り）を過ぎたら、追補 2 §3 の規則を当てはめる。
>        - commit が 1 つも無い → V1'。
>        - 1 つ以上ある → 後継が戻れば `promoting`、戻らなければ commit 済みの replica を後継に替える。
>      - この判定も、status を CAS で書いてから送る。
> 2. **binding を照合する**（pod UID・boot id・copy id。`prepared` に保存した値）
>    - **V2 を送る直前**: 各 replica の binding を新しく読み直す。保存した値と違う、または読めない replica には送らない。
>      - 同名で作り直された Pod、再起動した process、入れ替わったコピーのいずれも、ここで外れる。
>      - その replica は `prepared` から外す（CAS）。従来どおり full rebuild。
>      - 同じ process なら `history discard` も送る。別の process なら pending は期限で消える。
>    - **commit の確認**: 次をすべて満たしたときだけ、`committed` に数える。
>      - binding が保存した値と同じ。
>      - `history_pending = -`。
>      - epoch = toEpoch。
>      - master_id = Entry の masterId。
>      - `node_map_version ≥ V2`。
>    - **再起動の後に committed を組み立て直すとき**: 同じ条件で読み直す。binding が違う Pod は数えない。
>      - tmpfs なら、同名の新しい Pod はコピーを持たない。PVC なら copy id が変わっている。
>    - **代わりの後継を選ぶとき**（追補 2 §3）: 上の条件で `committed` に数えられる replica だけから選ぶ。
>    - 試験
>      - `committingReplicas` の途中で prepare 済みの replica の Pod を削除し、作り直させる → その Pod は数えず、full rebuild する。他の replica は継続する。
>      - 応答が分からない CAS（test seam で status の patch を遅らせる）→ 送らずに読み直す。
>      - leader の交代の間に古い leader が送らないこと。


> **追補 2（2026-11-06、追補 1 8f33b11 への reviewer の指摘 P1）**
>
> 1. **宛先を絞って送る**
>    - `TopologyBroadcast.broadcastTopologyToPods (keys : List String)` を新設する。
>      - 送り方は `broadcastTopologyToAllPods` と同じ（宛先ごとの task、15 s の上限、応答の確認）。
>      - 違いは、map の node key が `keys` に入っている Pod にだけ送ること。
>    - 送る直前ごとに、operator の lease guard を確かめる。
>      - 条件は、自分が leader で、`heldUntil − now ≥ 送信の上限 + 1 s`。
>      - 足りなければ送らない。その tick では何もしない。
>    - 送った後にもう一度 `heldUntil > now` を確かめてから、phase を進める CAS を書く。
>    - CAS は既存の `status.handovers` と同じく、resourceVersion で行う。
> 2. **永続化する phase**（`status.handovers[]` の Entry に足す）
>    - phase に `preparing` と `committingReplicas` を加える。順は `draining → preparing → committingReplicas → promoting → done`。
>    - Entry に足す項目
>      - `hid`
>      - `seq`（S）
>      - `toEpoch`
>      - `masterId`
>      - `prepared`（prepare 済みの node key と、その時点の binding）
>      - `committed`（commit を確かめた node key）
>    - operator が再起動しても、leader が交代しても、この Entry から同じ phase の続きを行う。
>
> | phase | すること | 次へ進む条件 | 失敗・期限切れ・再起動 |
> |---|---|---|---|
> | `preparing` | 後継に `promote_prepare`、eligible な replica に `prepare`。L を前後で 2 回読む | 後継の prepare と、1 つ以上の replica の prepare が成功し、L の前後が一致 | prepare 済みが 0 なら、継続なしで従来の `promoting` へ。後継の prepare が失敗したら、全員に `history discard` を送り、従来の `promoting` へ。期限切れも同じ。再起動したらこの phase をやり直す（prepare は冪等） |
> | `committingReplicas` | V2 を `prepared` にだけ送る（1） | `prepared` の全員が `node_map_version ≥ V2`、`history_pending = -`、epoch = toEpoch を報告 → `promoting` | **commit が 1 つでも確かめられたら、V1' で旧 master に戻すことはしない**（commit 済みの replica は旧 epoch の転送を拒否するため）。期限内に確かめられなかった replica は継続から外す（後で full rebuild）。下の「後継が止まったとき」を参照 |
> | `promoting` | V2 を後継に送り、続けて旧 master と残りに送る | 既存の条件（全 Pod が V2、後継の own_role が master） | 既存どおり |
>
> 3. **後継が止まったとき・応答が分からないとき**（`committingReplicas` で、1 つ以上が commit 済み）
>    - 後継の Pod が同じ process のまま `Th` 内に戻れば、V2 を送って `promoting` へ進む。
>    - 戻らない（Pod が無い、別の process、期限切れ）ときは、旧 master に戻さない。**commit 済みの replica の 1 つ（map 順の先頭）を後継に替える。**
>      - その replica の中身は H の時点の旧 master と同じで、S の後の書き込みは無い。H から昇格までの間、master はいなかったからである。
>      - そのため、昇格させても書き込みを失わない。
>      - その replica は successor の pending を持たないので、昇格のときに epoch を通常どおり進める（E' → E''）。
>      - 他の commit 済みの replica は `epoch_mismatch` になり、full rebuild する。データは失わない。冗長度は一時的に下がる。
>    - commit 済みが 0 なら、従来どおり V1' で旧 master に戻す。
>    - 旧 master は、どちらの場合も E のまま残る。その後は proxy か replica として full rebuild する。
>    - operator の交代や再起動では、`committed` を各 replica の stats（`history_pending`、epoch）で読み直してから、上の規則を当てはめる。
> 4. **追加する試験**
>    - E2E: 2 つの replica のうち 1 つにだけ V2 を届ける（test seam `FLARE_TEST_BROADCAST_SKIP_FILE`）→ 部分的に commit した状態で後継の flared を kill する。
>      - 確かめること: commit 済みの replica が master になり、missing 0・エラー 0。もう 1 つの replica は full rebuild。旧 master に戻らない。
>    - E2E: `committingReplicas` の途中で operator を再起動し、leader を交代させる → 同じ規則で続く。
>    - E2E: lease を失わせる（`FLARE_TEST_LEASE_API_STALL_FILE`）→ 旧 leader は V2 を送らない。
>    - unit: phase の状態機械（各遷移、再起動からの再開、commit 済みの数による分岐）。


> **追補 1（2026-11-06、実装中に見つかった順序の問題。reviewer の確認待ち）**
>
> 第 2 版 §4-4 では、prepare 済みの replica は V2 を受け取ったときに commit する。しかし V2 の配布順が既存どおり「後継 → 旧 master → 残り」だと、次のことが起きる。
> 1. 後継が先に master になり、新 epoch E' の転送を始める。
> 2. まだ V2 を適用していない replica には epoch E が残っているので、E' の転送を `_decide_change` で拒否する。
> 3. これが drop・failed として数えられ、replica repair、つまり full rebuild になる。
>
> **改める点（A3 の operator で実装する）**
> - 継続する引き継ぎ（prepare 済みの replica がいるもの）では、V2 を次の順で配る。
>   1. prepare 済みの replica に V2 を送る。
>   2. その全員が `node_map_version ≥ V2` と `history_pending = -`（commit 済み）を報告したことを確かめる。
>   3. その後で、後継に V2 を送る。
>   4. 最後に、旧 master と残りに送る。
> - 1 と 2 の間、master はいない。V1 の後と同じ状態で、書き込みは W で待つ。この時間も `Th` に含めて測る。
> - 2 で期限内に確かめられなかった replica は継続から外す。
>   - その replica の pending は、後継が commit した後に E' の転送が拒否されて repair、つまり従来どおりの full rebuild になる。
>   - 引き継ぎ自体は進める。
> - 先に commit した replica は、後継の昇格を待つ間、旧 epoch E の転送を拒否する。しかしバリアの条件（旧 master から in_flight 0）で、旧 epoch の転送はもう無い。
> - 後継の commit（昇格時）が失敗した場合は、通常どおり epoch を進める（`history_on_promotion` が -1）。
>   - commit 済みの replica は E'、新 master は E'' になり、`epoch_mismatch` から full rebuild になる。データは失わない（安全側）。
> - flared 側（A2、`cluster.cc`）: replica は、map が prepare 済みの後継を partition の Active な Master と示したときに commit する。別の master を示したら pending を捨てる。
>   - 後継は昇格の処理（`_shift_node_role`）の中で commit し、epoch をもう一度進めない。


> **第 6 版の変更（2026-11-06、第 5 版 855dbc6 への reviewer の指摘 P1 2 点）**
>
> 1. **「全部残す」の具体値と、その根拠**
>    - RocksDB の版
>      - 本番の image は Ubuntu noble の `librocksdb8.9`（`Dockerfile.flare-node-rocksdb`）。
>      - nix の試験は nixpkgs の 8.3.2。
>      - 試験は両方の版で行う。nix-linux の cutter と、image の E2E。
>    - 前提にする仕様（公式の Options の説明）
>      - `WAL_ttl_seconds` と `WAL_size_limit_MB` が両方 0 なら、不要になった WAL はすぐ削除される。
>      - どちらかが 0 でなければ、archive に移される。
>      - archive の削除は、TTL か size を超えたときだけ。
>      - `WAL_ttl_seconds` が 0 でなく `WAL_size_limit_MB` が 0 なら、TTL だけで消す。
>      - flared は今、両方を設定している（`storage_rocksdb.cc:241-242`）。
>    - marker が有効な open での値
>      - `WAL_ttl_seconds = 315360000`（10 年）、`WAL_size_limit_MB = 0`。
>        - 不要になった WAL は archive に移り、10 年は消えない。
>      - `recycle_log_file_num = 0` を明示する。
>        - recycle は WAL の内容を上書きして `GetUpdatesSince` を壊すため。今も使っていないが、明示して検査する。
>      - RocksDB に open 時の後片付けを止める option があれば使う（実装時に 8.3.2 と 8.9 で確かめる）。
>        - 根拠にはしない。上の値だけで守れることを、次の試験で示す。
>    - **示す試験**（設計の合格条件に入れる）
>      - E2E `history-continuation-wal-pin-restart`
>        1. 新 master の WAL の設定を小さくする（`walTtlSeconds 60`、`walSizeLimitMb 16`）。
>        2. 保持の間に、上限を超える量の WAL を作る（数十 MB の書き込み）。
>        3. 新 master の flared を kill -9 し、TTL より長く（90 s）止めてから起動する。
>        4. 起動の後、follower の `repl_sync_wal S+1` が成功し、`lsn_purged` にならないことを確かめる。
>        5. 同じ手順を marker 無しでも行い、そちらは `lsn_purged` になることを確かめる。
>           - これで、この試験が実際に削除の条件を作っていることを示す（対照）。
>      - cutter `test_wal_pin_open`
>        - 8.3.2 で、TTL と size を小さくした DB を作り、archive に WAL を置く。
>        - marker の値で open した後、S+1 からの `GetUpdatesSince` が読めることを示す。
>        - 対照として、通常の値で open すると読めないことも示す。
> 2. **marker が読めないときは fail closed**
>    - `WAL_PIN` が存在する限り、「marker 無し」としては扱わない。次のどれでも、保護の値（上の値と、open 直後の `DisableFileDeletions`）で open する。
>      - 読めない（権限、I/O エラー）
>      - 形式が違う（項目の数、数値でない、hid が空）
>      - 期限を安全に判定できない
>        - 時計が期限より大きく遅れている。目安は、期限が今より保持の上限（設定の 2 倍）より先にある。
>        - 時計が読めない。
>    - そのとき
>      - CRITICAL のログを出す。
>      - stats `wal_pin_state=invalid` と、その理由を出す。
>      - marker は自動では消さない。
>    - 解き方は 2 つ。
>      - operator が、stats で読んだ内容に合う `history_release <hid>` を送る。
>      - 内容を読めない marker は、人が承認して `history_release_invalid <起動の boot id>` を送る。
>        - 記録を残す。
>        - 他の起動の指示とは取り違えない。
>    - 空きの下限に当たったときは、invalid のままでも保持を解く（第 4 版 §3 と同じ）。
>      - master のデータは失わない。
>      - follower は full rebuild に戻る。
>      - これは、記録された例外として扱う。
>    - 期限が正しく読めて、その期限が過ぎている marker だけを、起動時に消してよい。
>    - 試験
>      - 壊れた marker、読めない marker（権限 000）、期限が遠い未来の marker のそれぞれで、保護の値で open し、`wal_pin_state=invalid` になる。
>      - 解除の指示で通常に戻る。


> **第 5 版の変更（2026-11-06、第 4 版 8e4020c への reviewer の指摘 P1）**
>
> 第 4 版 §4 の保持の意図は、RocksDB の default CF に置いていた。
> - これでは、起動時の `DB::Open`（`storage_rocksdb.cc:1503`）が WAL・obsolete file の後片付けをするのが、意図を読むより先になる。
> - `DisableFileDeletions` も DB handle を得た後でしか呼べない。
> - そこで、意図を **DB の外に**置き、open の前から効かせる。
>
> 1. **marker を DB の外に置く**
>    - `data_dir/WAL_PIN` に `hid S deadline_epoch_ms` を書く。
>    - 書き方は一時ファイルに書いて fsync し、rename してから、ディレクトリを fsync する。
>    - 書くのは commit（V2 の適用）の前。消すのは release か期限切れの後。
>    - 同じ hid なら上書きしても同じ内容（冪等）。
> 2. **open の前に読む**
>    - flared は `_open_db` の前に `WAL_PIN` を読む。
>    - 期限が残っていれば、その open では次の設定で `DB::Open` する。
>      - `WAL_ttl_seconds` と `WAL_size_limit_MB` を「全部残す」値にする。
>        - flush 済みの WAL は削除されず archive に移るので、open の後片付けで消えなくなる。
>      - RocksDB に `disable_delete_obsolete_files_on_open` があれば、それも使う。
>        - nixpkgs の RocksDB の版で確かめる。無い・効かない場合は、上の WAL の設定だけで守れることを試験で示す。
>    - open の直後、まだどの follower にも答えないうちに `DisableFileDeletions` する。
>    - そのうえで、WAL の TTL と上限を通常の値に戻す。
>      - `SetDBOptions` で戻せるかを実装時に確かめる。
>      - 戻せなければ、保持を解くときに戻すまでその値のままにする。保持には期限と空きの下限があるので、増え方には上限がある。
>    - 期限切れの marker は、open の前に消す。その open は通常の設定で行う。
> 3. **release と期限**
>    - `history_release <hid>` と期限切れのどちらでも、次の順で行う。
>      1. `EnableFileDeletions`
>      2. WAL の設定を通常に戻す
>      3. `WAL_PIN` を消す
>      4. ディレクトリを fsync する
>    - この順なら、どこで落ちても次の起動は「保持あり」か「通常」のどちらかになる。
>    - 期限が過ぎた marker が残っていたら、起動時に消す。
> 4. **順序を試験できるようにする**
>    - test seam を置く。どれも本番では設定しない。
>      - `FLARE_TEST_WAL_PIN_CRASH_AT`: marker を書いた後、DisableFileDeletions の後、release の各段で flared を落とす。
>      - `FLARE_TEST_OPEN_HOLD_FILE`: open の直前で止める。
>    - E2E で確かめること
>      - 保持の間に新 master を kill -9 し、再起動の後も follower が `repl_sync_wal S+1` で続けられる（`lsn_purged` にならない）。
>      - release の途中で落としても、次の起動は保持ありか通常のどちらかになり、WAL が残り続けない。
>      - 期限切れの marker があっても、通常どおり open する。
>    - cutter: marker の読み書きと、期限・hid の判定。


> **第 4 版の変更（2026-11-06、第 3 版 338c2fe への reviewer の変更要求を受けて）**
>
> 第 3 版の節（cursor の一致を根拠にする）は維持する。次の 4 点を加える・改める。
>
> 1. **完了条件と pf-dev（follow off）の扱い**
>    - この Issue の完了条件は次の 2 つ。
>      - follow が有効なクラスタで、計画的な master の切替で残りの replica が full rebuild しないこと（実装、unit、E2E）。
>      - follow が無効なクラスタでは、従来どおり full rebuild になること（変わらないことの確認）。
>    - pf-dev で follow を有効にするのは、別の Issue（`flare-pfdev-follow-on`）で行う。
>      - 負荷と CPU を検証し、ユーザーが判断する。
>    - **残るリスク**: pf-dev で follow を有効にするまでは、master の切替で残りの replica が full rebuild になる。
>      - tmpfs では `no_space` で止まる。
>      - それまでの運用: master の切替（master の node の cordon・drain、rc の入れ替え）を避ける。
>      - 避けられないときは、止まった replica のコピーを `FlareCopyDiscardApproval` で捨てるか、容量を増やす。どちらもユーザーの判断で行う。
> 2. **H で L が動かないこと**
>    - V1 の後も、source（旧 master）の sequence は書き込み以外で進み得る。
>      - reaper の削除、orphan_purge、lazy expire の物理削除、metadata・cursor の Put。
>    - そこで `maintenance_pause <hid>` を、旧 master・後継・各 replica の全員に送る（期限付き）。
>      - 止めている間は、これらの変更を起こさない。
>      - L1 の書き込み区間で、止まったことを確認する。
>    - L は、比較の前後で 2 回読む。
>      - 1 回目は全 replica の cursor を読む前、2 回目は prepare の直前。
>      - `L_before == L_after` のときだけ継続を許す。動いていたら、継続をあきらめて full rebuild に回す（安全側）。
>    - stats の読み取りは、毎回 END まで揃ったものだけを使う。
>      - 読み取りは pod UID・boot id・copy id・epoch に束縛する。読んだ値と prepare の要求で、これらが同じであることを確かめる。
>      - follow の状態（following）と identity の確認は残す。
> 3. **WAL の保持の上限と、上限に達したとき**
>    - `DisableFileDeletions` の間は、WAL の TTL もサイズの上限も効かない（既存の snapshot のコメントと同じ）。
>      - そのため `walSizeLimitMb` を上限には使えない。
>    - 保持の上限は、空き容量で決める。
>      - 新 master は、保持の間、データディレクトリの空き（tmpfs では `rebuild_space_available` と同じ計算）を 1 秒ごとに見る。
>      - 空きが下限を下回ったら、すぐに保持をやめる。下限の既定は `rebuildReserveBytes` の 1/2、設定で変えられる。
>    - 保持の期限は既定 120 s。follow の poll は 200 ms なので、通常は数秒で全員が S を越える見込み（E2E で測る）。
>    - 保持をやめた後に `lsn_purged` になった follower は、full rebuild に戻る。master のデータは失わない。
>    - E2E では、保持の間の WAL の増分（MB）、空きの最小値、保持の時間を記録する。
> 4. **保持を再起動に耐えるようにする、release を冪等にする**
>    - 保持の意図（hid、S、期限）は、default CF に 1 バッチで永続化する。
>      - flared は起動時、WAL の削除を始める前に意図を読む。
>      - 期限が残っていれば、もう一度 `DisableFileDeletions` する。
>    - `history_release <hid>` は冪等にする。
>      - 意図を消し、保持を解く。同じ hid の 2 回目の release は何もしない。
>      - 期限切れでも同じ扱いにする。
>    - 追加する試験
>      - 保持の間に operator を止める → 期限で解ける。
>      - 保持の間に新 master の flared を再起動する → 意図から保持が戻る。期限で解ける。
>      - 1 つの follower を長く止める → 期限か空きの下限で解ける。その follower は full rebuild、他は継続。
>      - release の再送。
>      - 空きの下限に当たる負荷 → すぐに保持をやめ、エラー 0。


> **第 3 版の変更（2026-11-06、第 2 版 2f2b0e3 への reviewer の変更要求を受けて）**
>
> 継続の可否を、ダイジェスト D ではなく **WAL follow の適用位置**で判定する。
> 対象は WAL follow が有効なクラスタに限る（rc70 の chart の既定は有効）。以下の §3・§4-1/2・§8 は、この節が上書きする。
>
> 1. **根拠を cursor に戻す。ただし follow が有効なときだけ。**
>    - 第 1 版で cursor を使えなかったのは、follow off の replica では転送で cursor が進まないからだった。
>    - follow が有効なら、cursor は「その位置までの master の全履歴を、連続して適用した」ことを表す。
>      - `design-continuous-wal-replication.md` §3.4: "Everything up to the cursor has already been applied"
>      - 適用は連続性の検査付き（`storage_rocksdb.cc:5163`）。
>    - バリアの時点 H では、次をすべて満たす replica r を eligible@H とする。
>      - 旧 master は V1 を適用済みで、もう書き込まない。
>      - その最新の sequence を L とする。r の `repl_last_lsn == L`。
>      - r の follow の状態が following で、needs_rebuild ではない。
>      - epoch、master_id、incarnation が一致する。
>      - R3 の根拠に問題が無い。partial・quarantine・修復の未完了が無い。
>    - follow が無効な replica（pf-dev の今の設定）は eligible にならない。従来どおり full rebuild。
>    - ダイジェスト D（第 2 版 §3）と、初期値の走査は**やめる**。
>      - reviewer の §8-1（走査のコストと一貫性、全 mutator の列挙）と §8-2（hash の強さ）は、この経路では不要になる。
> 2. **遅れて届く転送**（reviewer §8-3 のコード確認を受けて）
>    - `track_repl_in_flight` は、宛先ごとに queue の前で加算され、`handler_proxy` が処理を終えたときに減算される。queue・retry・held を含む（同じ boot の中でだけ有効）。
>    - そこでバリアの条件は、宛先ごとの `proxy_write_in_flight[r] == 0` と、旧 master の boot id が開始時と同じこと、にする。
>    - `proxy_write_held` は累積の counter なので使わない。
>    - follow が有効なら、転送が落ちても WAL が埋めるので、cursor の一致で十分。転送の counter は「遅れて届くものが無い」ことの確認にだけ使う。
>    - commit の後に届いた旧 epoch の転送は、`_decide_change` で拒否される（第 2 版 P2 と同じ）。逆順の試験は残す。
> 3. **replica の中だけで起きる変更**（lazy expire、orphan_purge）
>    - follow が有効でも、replica の中だけで起きる削除は、今の継続複製と同じだけずれる。
>    - 第 2 版と同じく、引き継ぎの間は止める（`maintenance_pause <hid>`）。
>    - ずれの許容は、今の継続複製の保証と同じ範囲にとどめる（新しい保証は足さない）。
> 4. **re-base の後の WAL の保持**（reviewer の追加 P1）
>    - re-base した follower は、新 master の WAL を S+1 から読む。
>    - 新 master（後継）は commit の時点で WAL ファイルの削除を止める（RocksDB `DisableFileDeletions`）。
>    - 削除を再開する条件は、どちらかが成り立ったとき。
>      - prepare 済みの全 replica が cursor > S を報告した（operator が `history_release <hid>` を送る）
>      - 期限（既定 10 分）が切れた
>    - tmpfs では、止めている間の WAL の増え方が memory に入る。期限と `walSizeLimitMb` で上限を決めて記録する。
>    - 期限が切れた後に `lsn_purged` になった follower は、full rebuild に戻る。tmpfs では `no_space` になり得る。これは残る制約として合格条件に書く。
>      - E2E では、通常の負荷で 1 件も起きないことを示す。
> 5. **prepare / commit、meta CF を捨てない、master_id の扱い**は第 2 版の §4-3〜6 のまま。
>
> pf-dev で効かせるには、overlay の `replFollowEnabled: false` を外す必要がある。
> - false にした理由は、follower の poll の CPU コストだった。
> - rc70 で直っている: replica 側の可視化 p99 が 61 → 1.8 ms（visibility-bench 41562977684 → 41563019456）。
> - pf-dev で follow を有効にするのは、別の PR とユーザーの判断で行う。


Issue: `flare-promotion-forces-rebuild`（ユーザー承認 2026-11-05: 案 A）。
土台: gree/flare 77ea6e6（v0.1.0-rc70）。
第 1 版（2bf25d3）への reviewer の指摘（2026-11-06、Issue note）を受けて書き直した。
対応表は §9。

## 1. 問題（第 1 版と同じ）

- 昇格すると、flared は必ず source epoch を進める（`cluster.cc:2649-2683`）。
- source はこの epoch と違う follower を拒否する（`op_repl_sync_wal.cc:220`）。
- そのため、順序付き引き継ぎでも、残りの replica が毎回 full rebuild になる。
- tmpfs では、古いコピーを残すと `no_space` で止まる。
- ユーザーの要件: master を切り替えたときに全台を再構築しない。古いコピーを生かす。

## 2. 前提となる事実

1. replica の cursor は、転送された書き込みでは進まない（`storage_rocksdb.cc:4778`）。
   - そのため、cursor を中身の証拠には使えない。
2. 転送の label は `source_epoch/seq_label`（master 自身の sequence）。
   - replica はこれを key ごとの meta 行 `epoch|label|deleted` に記録する。
   - **epoch が違う meta 行は「該当なし」として扱われる**（`_decide_change`、`:4631-4648`）。
3. 昇格時に、旧履歴と新履歴の対応は記録されない。
4. 順序付き引き継ぎの drain が調べるのは後継だけ（`Main.lean:794-796`）。
5. 転送の再送は 2 種類ある（`queue_proxy_write.cc:351-395`、`:462-500`）。
   - 通常は `max_retry` 回まで再送し、尽きたら `proxy_write_dropped[dest]` を数える。
   - 保留された転送（held）は、`foreign_retry_window_ms`（120 s）まで待つことがある。
6. column family の Drop/Create は WriteBatch に入らない（reviewer 指摘 2）。

## 3. 考え方（第 2 版）

第 1 版は「drain の counter が増えていない」から中身の一致を推論していた。しかし、それ以前の欠落は除外できない（reviewer 指摘 1）。
第 2 版では、**中身の一致を直接比べる**。

- **論理内容のダイジェスト**（新）
  - flared が copy ごとに、ユーザーに見える論理値の集合のダイジェスト D を持つ。
    - 論理値: key、value、flag、期限（exptime）、version、削除済みかどうか。
  - 順序に依存しない形にする。key ごとの 128 bit hash の和（mod 2^128）。
  - 書き込みと削除のたびに、書き込み区間の中で増減させる。
  - copy を開くときに 1 回だけ全走査して初期値を決める。
    - rc68 の tombstone 件数（`repl_tombstones seeded by an exact scan`、`:5092`）と同じ形。
  - 初期値が決まるまでは UNKNOWN。UNKNOWN の copy は継続の対象にしない。
  - 一致しなければ、その replica は従来どおり full rebuild。**ダイジェストは安全を保証する仕組みではない。継続してよいかの判定だけに使う。**
- 時点 H（バリア）では、旧 master も replica も書き込みを適用していない。そこで D を比べる。
  - D(replica) = D(旧 master) = D(後継) なら、論理内容が一致する（hash の衝突を除く）。

## 4. 手順（2 相: prepare → commit）

既存の流れは demote（V1）→ drain → promote（V2）。

1. **バリア**（既存の V1 と drain に足す）
   - 旧 master が V1 を適用し、書き込みを適用しなくなったことを確かめる。L1 と W による。
   - 旧 master から全 replica への転送が終端していることを確かめる。
     - 宛先ごとに `proxy_write_in_flight[r] == 0`。
     - **held の転送が残っていない**（新しい stats `proxy_write_held[r] == 0`）。
     - **再送中の転送が残っていない**。in_flight が再送中も数えていることを、コードで確かめて試験する（§7）。
   - 各 replica（r）では、replica の中だけで起きる変更を引き継ぎの間だけ止める（`maintenance_pause <hid>`、期限付き）。
     - 対象は orphan_purge と、lazy expire による物理削除。
     - 理由は §8-1。
2. **比較**: 旧 master、後継、各 replica の D・epoch・master_id・incarnation を読む。
   - 継続の対象（eligible@H）にするのは、次を全部満たす replica だけ。
     - D が旧 master と等しい（UNKNOWN は不可）。
     - epoch と master_id が旧 master と同じ。
     - Active・Ready。
     - R3 の昇格の根拠に問題が無い。
     - partial ではない。quarantine が無い。修復の未完了が無い。
     - 開始時と同じ boot id・incarnation である。
   - 後継も同じ条件を満たすこと。満たさなければ引き継ぎを始めない（既存の中止）。
3. **prepare**（永続化するが、まだ有効にしない）
   - 後継に `promote_prepare <hid>` を送る。
     - 後継は次を作り、pending として永続化して返す。
       - 新しい epoch E'
       - 自分の最新の sequence S
       - 必要なら新しい master_id（`cursor > seq` の分岐はここで判定する）
     - 有効な identity は変えない。
     - 同じ hid では同じ値を返す（冪等）。
   - eligible@H の各 replica に `history_prepare <hid> <E> <E'> <S> <master_id'>` を送る。
     - replica は epoch == E と incarnation が開始時と同じことを確かめる。
     - pending を 1 つの WriteBatch で永続化して応答する。
   - 応答の無い replica、拒否した replica は、継続から外す（full rebuild に回る）。
4. **commit = V2 の適用**
   - V2 の map は hid を持つ。後継と prepare 済みの replica は、V2 を受け取ったときに pending を有効にする。
     - 1 つの WriteBatch で、epoch・cursor・master_id・`rebuilt_from` を切り替える。
     - すべて default CF の予約キーなので、1 バッチに入る。
   - **meta CF は捨てない**。epoch を切り替えると、旧 epoch の meta 行は「該当なし」として扱われる（事実 2）。
     - 旧 epoch の行は、tombstone の GC で後から消す。GC と cursor の規則には epoch の条件を足す（§8-3）。
   - prepare していない replica は、従来どおり epoch_mismatch から full rebuild。
5. **abort**（V2 の前の中止 = 既存の V1'）
   - pending を捨てるだけで済む。有効な状態は何も変えていない。
   - 期限が切れた pending は、起動時と定期的に捨てる。
   - replica の `maintenance_pause` も解く。
6. **障害時**
   - prepare の後に replica が再起動した場合:
     - 起動時に pending が残っていて、map がまだ旧 master を示していれば、pending は保留のままにする。
     - V2 が来れば有効にする。V1' か期限切れなら捨てる。
   - 後継が prepare の後に落ちた場合: 既存の中止。旧 master に戻る。
   - W の上限: 1〜4 の間も書き込みは W で待つ。期限の扱い（`Th + Tb < Tw`）は変えない。
     - D の比較と prepare の時間を `Th` に含めて測る。
     - 足りなければ prepare をあきらめ、その replica は full rebuild に回す。引き継ぎ自体は進める。**エラー 0 を優先する。**

## 5. 安全性の根拠

- **P1（中身の一致）**: eligible@H の replica は、H で旧 master と論理内容が一致する。
  - 根拠: D が等しい（衝突の確率は 2^-128 程度）。
  - 根拠: H では、書き込みと replica 内の変更を止めている。
- **P2（遅れて届く旧 epoch の書き込み）**: H の後に旧 epoch の転送が届いても、適用されない。
  - commit の後は epoch が E' なので、旧 epoch の転送は拒否される（`_decide_change`）。
  - commit の前に届けば、それは H の前の転送の再送になる。その書き込みはすでに D に入っている。
  - 再送や held の終端性で、H の後に新しい旧 epoch の転送は生まれない。
  - 試験: 逆順に届く set・delete（§7）。
- **P3（S 以降の継続）**: 後継は H から V2 まで書き込みを受けない。そのため、新 master の WAL の S+1 以降が E' の全変更になる。
- **P4（切替の原子性）**: 有効にするのは default CF の 1 バッチ。meta CF には触れない。
  - 途中で落ちたら、旧の状態か新の状態のどちらかで起動する。
- **P5（取り違えない）**: hid・E・incarnation の一致が前提。冪等。
- **P6（二重 master にならない）**: 既存の性質を変えない。

## 6. 使えないとき（従来どおり full rebuild）

- 計画的でない failover。
- D が一致しない、または UNKNOWN の replica。
- prepare できなかった replica。
- legacy（rc70 より前）の master。

## 7. 試験

- E2E（tmpfs、3 コピー、書き込みを流しながら）
  - master の削除、cordon 移設、OnDelete のローリングで、残りの replica が full rebuild しない。
    - `rocksdb_staged_switched` と `snapshot_bootstrap` が増えない。
  - エラー 0・missing 0。全 key・値・期限が一致する。
- 負の試験
  - 1 つの replica への転送を落とす → D が一致しないので、その replica だけ full rebuild。
  - held の転送を残したまま → バリアで待つ。期限内に終わらなければ、prepare をあきらめる（エラー 0）。
  - 旧 epoch の set・delete を、commit の後に逆順で届ける（test seam で遅らせる）→ 拒否され、D が変わらない。
  - prepare の後の abort、replica の再起動、後継の再起動、期限切れの pending。
  - `cursor > seq` の分岐と通常の分岐の両方。
  - 期限の境界: 期限ちょうどの key を、引き継ぎの前後で読む。
- cutter（flared）
  - D の増減（set・add・replace・cas・incr・delete・expire）と、初期値の走査との一致。
  - pending の永続化、冪等性、有効化の原子性。

## 8. 決めたこと・残りの論点

1. **replica の中だけで起きる変更**
   - lazy expire は、読み取りで期限切れの key を物理的に消すことがある。消える時刻は master と replica で違い得る。
   - そこで、D には「期限切れでも物理的に残っている key」も入れる（論理値に期限を含める）。物理削除のたびに D を減らす。
   - そのうえで、引き継ぎの間は物理削除を止める（`maintenance_pause`）。止めないと D がずれ、継続できないだけになる（安全側）。
   - orphan_purge も同じく止める。
2. **prepare と commit**: 第 1 版の「先に re-base して、中止なら戻す」はやめた。pending 方式にした。
3. **meta CF と tombstone**
   - meta CF は捨てずに epoch で無効にする。
   - GC は旧 epoch の行を消す。cursor の規則（`label <= cursor`）は、同じ epoch の行だけに適用する。
   - abort の後は epoch が E のまま。meta 行も残っているので、抑止の情報は失われない。
4. **master_id**: prepare で判定と生成をし、commit で公開する。
5. **残る論点**
   - D の初期値の走査のコスト（4.7 GB で数十秒の見込み、未計測）。
   - 128 bit の加算ダイジェストで十分か。
   - `proxy_write_in_flight` が再送中・held 中も数えているか（コードで確認する）。

## 9. 第 1 版への指摘と対応

| 指摘 | 対応 |
|---|---|
| clean@H は counter の差分では証明できない | 論理内容のダイジェスト D を直接比べる（§3、§4-2） |
| meta CF の Drop/Create は WriteBatch に入らない | meta CF を捨てない。epoch で無効にし、有効化は default CF の 1 バッチ（§4-4、§5 P4） |
| in_flight 0 は、遅れて届く再送が無い証明にならない | held と再送の終端をバリアの条件にする。commit の後の旧 epoch は拒否する。逆順の試験（§4-1、§5 P2、§7） |
| re-base を先にして undo する方式は選べない | prepare（pending）→ V2 で commit。abort は pending を捨てる（§4-3〜5） |
| tombstone・meta の破棄 | 破棄しない（§8-3） |
| regenerate_master_id | prepare で判定・生成、commit で公開（§4-3、§8-4） |
| lazy expire と orphan_purge | 期限を含む論理値で比べる。引き継ぎの間は物理削除を止める（§8-1） |
