# 順序付き引き継ぎで履歴を継ぐ（replica を full rebuild しない）— 設計案

Issue: `flare-promotion-forces-rebuild`（ユーザー承認 2026-11-05: 案 A）。
土台: gree/flare 77ea6e6（v0.1.0-rc70）。事実の出典は各行の `file:line`
（調査 2026-11-06、next/rebuild-copy-space 6cdbbd8）。

## 1. 問題

- 昇格すると、flared は必ず source epoch を進める（`src/lib/cluster.cc:2649-2683`）。
- source はこの epoch と違う follower には WAL を渡さない（`op_repl_sync_wal.cc:220`、`epoch_mismatch`）。
- そのため、順序付き引き継ぎ（rc70 同士）でも、残りの replica は毎回 full rebuild になる。
- 影響
  - 引き継ぎのたびに、master 以外の実コピーが一時的に無くなる。
  - tmpfs では、古いコピーを残したまま rebuild に入るので `no_space` で止まる。
  - pf-dev 2026-11-05: 7.17 GB 必要、空き 3.64 GB。
- ユーザーの要件: 「master 切り替えで全台再構築はありえない」。古いコピーを生かす。

## 2. 前提となる事実

1. replica の cursor（`repl_last_lsn`）は WAL apply と再構築でしか進まない。
   - 転送された書き込みでは進まない（`storage_rocksdb.cc:4778` "The forwarded path does NOT advance the replication cursor"）。
   - そのため follow off の replica では、cursor は「最後の再構築の位置」のままになる。中身（転送で更新された内容）とは一致しない。
   - **この設計は cursor を中身の証拠に使わない。**
2. 転送の label は、master 自身の sequence（`seq_label = GetLatestSequenceNumber()`、`:1927`/`:2119`）と epoch の組（`queue_proxy_write.cc:86-91`）。
   - replica はこれを key ごとの meta 行 `epoch|label|deleted` に記録する（meta CF）。
3. 昇格時には、「旧履歴のどこまでが新 master の何番に当たるか」は記録されない（調査で見当たらない）。
4. 順序付き引き継ぎの drain が調べるのは**後継だけ**（`Main.lean:794-796`）。
   - 調べる値は `proxy_write_in_flight` / `dropped` / `failed`。
   - 他の replica への転送は確かめていない。
5. 履歴が変わるときは、meta CF を捨てて作り直す（`storage_rocksdb.cc:1097`、`:3104`）。
   - label は別の sequence 空間の値だから。

## 3. 考え方

cursor ではなく、**引き継ぎの時点 H で全コピーの中身が等しいこと**を drain で証明する。
そのうえで、各 replica の位置を新 master の sequence 空間に付け替える（re-base）。

時点 H は次の状態をいう。
- 旧 master は降格の map（V1）を適用済みで、書き込みをもう適用しない。
  - L1 の書き込み区間で保証される。
  - 新しい書き込みは W で待つ。
- 旧 master から各 replica への転送が、すべて成功で終わっている。

この時点では、次の 3 つの中身が等しい。
- 旧 master のデータ
- 後継のデータ
- 「H で清浄」と判定した replica のデータ

## 4. 手順（operator が駆動する。今の引き継ぎに 2 段を足す）

既存の流れは demote（V1）→ drain → promote（V2）。

1. **drain を全 replica に広げる**（新）。
   - 旧 master の宛先ごとの counter を、後継以外の各 replica についても読む。
     - `proxy_write_in_flight[r] == 0`
     - `proxy_write_failed[r]` と `proxy_write_dropped[r]` が、引き継ぎ開始時の基準値から増えていない
     - 基準値は、旧 master の boot id・copy id と組で記録する（既存の F）。
   - 加えて r 自身が次を満たすこと。
     - Active・Ready
     - boot id と incarnation が開始時と同じ（再起動もコピーの入れ替えも無い）
     - replica repair の未完了が無い
     - 自分の source epoch が旧 master の epoch E と同じ
   - これを全部満たす r を、**H で清浄（clean@H）**と記録する（`status.handovers[].cleanReplicas`、CAS）。
   - 満たさない r は従来どおり full rebuild に回す。引き継ぎ自体は止めない。
2. **後継に、昇格の準備として新しい履歴を先に作らせる**（新、`promote_prepare <handover-id>`）。
   - 後継はまだ slave で、W により書き込みは届かない。
   - その状態で次を行い、`(E', S, master_id)` を返す。
     - 新しい epoch E' を作る。
     - 自分の最新の sequence S を読む。
     - 継承の記録 `{handover-id, from_epoch E, to_epoch E', at_seq S}` を永続化する。
   - 昇格（V2）ではこの E' を使い、もう一度は進めない。
     - 既存の `_master_epoch_advanced` と同じ「1 回の在任に 1 回」の扱い。
   - cursor > seq のとき `regenerate_master_id` する分岐（`cluster.cc:2672`）も、ここで行う。新しい master_id を返す。
3. **clean@H の各 replica を re-base する**（新、`history_rebase <handover-id> <E> <E'> <S> <master_id>`）。
   - replica は、自分の source epoch が E で、incarnation が開始時のものと同じことを確かめる。
   - そのうえで、次を**1 つの WriteBatch で**行う。
     - source epoch を E' にする。
     - cursor を S にする。
     - master_id を新しいものにする。
     - meta CF を捨てて作り直す。
       - 履歴を変える既存の 2 経路（`:1097`、`:3104`）と同じ扱い。
       - H より前の転送はすべて適用済みなので、旧 label の役目は終わっている。
     - `rebuilt_from` を `(master_id, E')` にする。
   - 応答と結果は再送しても冪等にする（handover-id ごとに記録する）。
   - 失敗・無応答の r は full rebuild に回す。
4. **promote（V2）を配る**。順番は既存どおり（後継 → 旧 master → 残り）。
   - re-base 済みの replica は、新 master からの E' の転送をそのまま受け入れる。
   - WAL の catch-up も S から続けられる（`epoch_mismatch` も `lsn_ahead` も起きない）。
5. **中止（V1'）**: 手順 4 の前に中止するときは、re-base を元に戻す。
   - re-base した replica には `history_rebase_undo <handover-id>` を送る。
     - 記録してある E と旧 cursor・旧 master_id に戻す。
     - meta CF は作り直したままになる。旧 label が無くても、転送の判定は「該当行なし」として扱われるだけなので、安全側。
   - 後継の準備は破棄する。
   - 戻せない replica は full rebuild に回す。
   - **未決**: 手順 3 と 4 の順序を逆にする（promote の後に re-base する）か。
     - 逆にすると中止が簡単になる。
     - ただし、promote から re-base までの間に届いた E' の転送が `identified_refused` になる。

## 5. 安全性の根拠（証明すべきこと）

- **P1（中身の等しさ）**: clean@H の replica r の中身は、H での旧 master の中身と等しい。
  - 根拠: L1、旧 master は V1 以後に適用しない。
  - 根拠: r への転送の成功終端、in_flight 0、failed・dropped が増えていない。
  - 根拠: r に再起動・コピー入れ替え・修復が無い。
  - 例外: replica の中だけで起きる変更（lazy expire、orphan_purge）。これらは旧 master でも同じ規則で起きる。ずれを許すかの議論が要る（§8）。
- **P2（後継も等しい）**: 後継も clean@H の条件を満たすので、P1 と同じく中身が等しい（既存の drain の条件に含まれる）。
  - 後継の DB の sequence S は、H の時点の後継自身の中身を表す。
- **P3（S 以降の継続）**: 新 master が S の後に書くものは、すべて新 master の WAL の S+1 以降にあり、E' の label で転送される。
  - 根拠: L1 と W により、S を読んでから昇格までの間に後継は書き込みを受けない。
- **P4（re-base の原子性）**: epoch・cursor・master_id・meta CF の付け替えは 1 つのバッチで行う。
  - 途中で落ちたら、旧履歴のまま（re-base していない状態）で起動する。
- **P5（取り違えない）**: re-base は handover-id・E・incarnation の一致が前提。
  - 他の引き継ぎや別のコピーには効かない。
  - 古い指示を再送しても冪等。
- **P6（二重 master にならない）**: 既存の順序付き引き継ぎの性質は変えない（`atMostOneMasterPerPartition`）。

Lean 側では、手順 1〜5 の状態機械（`StateMachine/Handover.lean` の拡張）について次を unit とモデルで示す。
- clean@H の判定
- re-base の冪等性
- 中止時の戻し

## 6. 使えないとき（従来どおり full rebuild）

- 計画的でない failover（master に届かない）。drain ができないので H が無い。
- drain の条件を満たさない replica（遅れ、修復中、再起動した）。
- 旧 master が rc70 以前（legacy の経路）。
- 一部の replica だけ満たさないときは、満たす replica だけ re-base する。

## 7. 試験

- E2E（tmpfs、3 コピー、書き込みを流しながら）:
  - master の削除、cordon 移設、OnDelete のローリングのそれぞれで、残りの replica が full rebuild せずに Slave/Active を保つ。
    - `rocksdb_staged_switched` と `snapshot_bootstrap` が増えない。
  - エラー 0・missing 0。各コピーの全 key・値が master と一致する。
- 負の試験
  - 1 つの replica への転送を落とす（`proxy_write_dropped` を増やす）→ その replica だけ full rebuild、他は re-base。
  - re-base の途中で replica を kill → 旧履歴で起動し、full rebuild。
  - 中止（V2 の配布遅延）→ re-base の戻しの後、旧 master で継続。
  - handover-id 違いの re-base を拒否する。
- cutter（flared）
  - `history_rebase` の原子性と冪等性
  - `promote_prepare` の後の昇格で epoch を二度進めない

## 8. reviewer に確認したいこと

1. P1 の例外: replica の中だけで起きる変更（lazy expire の削除、orphan_purge）で、H の時点の中身が旧 master とずれる場合がある。
   - rc58 以降、reaper の削除は proxied delete で複製される。
   - ずれ得るのは「期限切れの key が replica では残っている／先に消えている」程度と見ているが、許容できるか。
2. 手順 3 と 4 の順序（re-base を先にするか後にするか）と、中止の扱い。
3. meta CF を作り直すことで、H より前の tombstone の情報を失って問題にならないか。
   - 例: 削除された key の古い値を、H の後に遅れて届いた転送で復活させないか。
   - H では in_flight が 0 なので、遅れて届く旧 label の転送は無いはず。
4. 後継の `regenerate_master_id` の分岐を準備段階に移してよいか。
