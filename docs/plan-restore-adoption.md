# 復元した履歴の採用：方針案（R8 復元ブロッカー）

状態：**提案（未実装・未承認）**。2026-10-08。

## 問題

SAF-10 の理由別昇格（ce8d661 / f9289aa 以降）では、operator は partition の
「最後の master の履歴」（master_id と source epoch）を記録し、それと違う履歴の
copy を昇格させない。backup の restore は、意図して過去の履歴へ戻す操作だが、
現行手順（docs/BACKUP_RESTORE.md Case A/B）には、その履歴を明示的に採用する
点がない。そのため restore 後に partition が master なしのまま止まる（eb7bc43、
run 37770467697、backup-restore 24）。通常の failover の一致規則は緩めない。
operator を再起動して記録を消す回避もしない（記録はメモリにしかなく、再起動で
消える。これ自体も弱点）。

## 前提

restore の元（source）と現行サービス（current）には触らない。復元は「別の場所に
作って確認してから切り替える」を基本とする。

## 案の比較

| | I. 既存クラスタ内での明示採用 | II. 隔離した新クラスタへの復元 |
|---|---|---|
| やること | 現行クラスタの PVC に checkpoint を戻し、pod を作り直す。新しい承認（CR または annotation：FlareCluster の UID、partition、backup の識別子、期待する履歴＝master_id／epoch）を作り、operator はすべての候補がその履歴を報告したときだけ採用して記録し、NOT LOSS-FREE としてログする | 新しい namespace／FlareCluster（新しい UID）を作り、backupBootstrap（RESTORED マーカーあり）で backup から seed する。新クラスタは初回構築として立ち上がる（記録された最後の履歴がないので、規則の例外ではなく「初めての master」として選ばれる）。検証（件数、キーの抽出確認）をしてから、切り替え（Web の向き先、または cluster replication／migration）は別のゲートで行う |
| current への影響 | **触る**：全 pod を作り直す＝停止。現行の copy は restore hook で `rm -rf` される（retention なし）。誤った backup を承認すると、それが現行の履歴になる | **触らない**：current はそのまま動き続ける。切り替えるまで影響なし |
| source への影響 | backup の読み取りのみ | backup の読み取りのみ |
| 必要な実装 | 承認 CR／annotation と operator の採用処理、履歴の記録を status に永続化、Case A の hook に RESTORED マーカー、置き換える copy の保持（retention）、multi-partition の partition 対応（Case C の既知の制限） | 新しい実装は最小の可能性：backupBootstrap と初回構築の承認（`first-build-approved`）は既存。ただし**理由別昇格の候補で動くことは未検証**。E2E（新クラスタ＋bootstrap＋初回構築＋全キー検証）の追加が必要。切り替え手順は R1/R4／Web 切替のゲートと一緒に決める |
| 必要な容量 | 追加なし | もう一つのクラスタ分（一時的） |
| 復旧時間 | 短い（pod の作り直し） | 長い（新クラスタ＋検証＋切り替え） |
| 誤操作の影響 | 現行サービスの履歴を置き換える（取り消せない） | 新クラスタを捨てればよい |
| 規則への影響 | 承認がないかぎり今の規則のまま（承認＝明示的な例外） | 規則に例外を加えない（初回構築として扱う） |

## 推奨

**II を標準の restore 手順にする。** current と source に触らず、既存の操作
（backupBootstrap、初回構築の承認）で足りる可能性がある。まず E2E で確かめる。
I は「現行クラスタがすでに使えない」場合の緊急手段として、承認・永続化・保持を
備えて別途設計する（今は実装しない）。

## 決めてほしいこと

1. 標準を II にするか。
2. I を将来の機能として残すか（残す場合、承認の形：CR か annotation か）。
3. 記録した最後の履歴を operator の status に永続化するか（operator の再起動で
   消えないように。I／II に関係なく、通常の failover の判断にも効く）。
