# 順序付き引き継ぎで履歴を継ぐ（replica を full rebuild しない）— 設計案 第 5 版

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
