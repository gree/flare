# needs_rebuild と「同一履歴の遅延」：判断材料（未決定・実装保留）

状態：**ユーザーの判断待ち。実装しない**（2026-10-09）。CI 37777862552 の
continuous-replication-limits「lagged successor」で、切り離されて遅れた follower が
`FORBIDDEN (R3: confirmed different history)` と分類され、partition が master なし
のまま止まった。

## flared の「needs_rebuild」は二種類ある（コードから）

| どこ | stat | 決め方 | 理由の値 |
|---|---|---|---|
| R3 読み取り元の検証（handler_source_validator, source_eligibility.h） | `repl_read_source_state=needs_rebuild`、`repl_read_source_reason` | コピーの lineage（master_id）と履歴（source epoch）を、**受け入れた map が名指す現在の partition master** と比べる。違えば needs_rebuild。現在の master がない、または比べられないときは needs_rebuild にしない（Unknown＝待つ） | 「lineage differs: copy X, master K Y」「history differs: copy E1, master K E2」 |
| WAL follower（handler_wal_follower） | `repl_follow_state=needs_rebuild`、`repl_follow_last_reason` | follow の応答による | `lsn_purged`（WAL の欠け）、`epoch_mismatch`、`master_id_mismatch`、`lsn_ahead`、`no_position`、`generations_unavailable` ほか |

operator の理由別判定（PromotionEvidence）は **R3 の `repl_read_source_state`** だけを
見て、needs_rebuild を常に FORBIDDEN にしている。follow 側の needs_rebuild は見ていない。

## 今回の事例で分かっていること・分からないこと

- 分かっている：follower は R3 needs_rebuild を報告し、置き換わった旧 master は空
  （empty）と分類された。
- **分からない**：R3 がどの master と比べたか（保存ログに follower の flared ログと
  `repl_read_source_reason` がない）。R3 は「現在の master」と比べるので、比べた
  相手が記録された最後の master か、その後に map に載った別の copy（例：空で戻った
  旧 master）かが、判断の分かれ目になる。次の失敗では試験がこれを記録する
  （`repl_read_source`、`repl_read_source_epoch`、`repl_read_source_reason`、follow の
  状態と理由、コピー自身の master_id／epoch）。

## 区別できること・できないこと

- 区別できる：R3 の理由（比べた相手の node key と epoch）と、follow の理由
  （WAL の欠け、apply error など）。
- **常に禁止のまま**（どの案でも変えない）：partial、quarantine、switch unresolved、
  in flight、parked、running、identity 不一致、master がいる間の revalidating。
- 「記録された最後の master と同一履歴」の根拠：今は operator のメモリにだけある
  記録（master が読めたときに更新）。operator の再起動で消える。永続化は別の設計
  （Unknown を空として扱わない条件つき）。

## 案（どれも未決定）

1. **今のまま**：R3 needs_rebuild は常に FORBIDDEN。遅れた唯一の copy があっても
   partition は master なしで止まる（可用性を失う。データは失わない）。試験の期待を
   「止まる」に変える。
2. **比べた相手で分ける**：R3 needs_rebuild のうち、比べた相手が記録された最後の
   master **ではない**（その後に map に載った別の履歴の copy）と `repl_read_source*`
   から確認でき、かつコピー自身の履歴が記録された最後の master と一致し、follow 側
   に WAL の欠け・apply error・corruption がないときだけ「遅延」として最終手段の対象
   にする（NOT LOSS-FREE）。それ以外の needs_rebuild は禁止のまま。記録がない／
   読めないときは Unknown（保留）。
3. 履歴一致だけで needs_rebuild を「遅延」に落とす：**広すぎる**（レビュー指摘）。
   採らない。

案 2 には、比べた相手の記録が要る（今は stat にあるが operator は使っていない）
こと、最後の master 履歴の記録の永続化と観測根拠が要ることを含む。運用の
トレードオフ（可用性かデータか）の判断はユーザーが行う。
