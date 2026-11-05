# 順序付き引き継ぎで履歴を継ぐ（replica を full rebuild しない）— 設計案 第 2 版

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
