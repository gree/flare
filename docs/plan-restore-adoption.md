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
| やること | 現行クラスタの PVC に checkpoint を戻し、pod を作り直す。新しい承認（CR または annotation：FlareCluster の UID、partition、backup の識別子、期待する履歴＝master_id／epoch）を作り、operator はすべての候補がその履歴を報告したときだけ採用して記録し、NOT LOSS-FREE としてログする | 新しい namespace／FlareCluster（新しい UID）を作り、backupBootstrap（RESTORED マーカーあり）で backup から seed する。新クラスタは初回構築として立ち上がる。ここでの「初めての master」は**map 上に履歴がない**という意味でしかなく、**復元した copy が健全であること、正しい partition のデータであることを自動では保証しない**（下の判定条件で確かめる）。検証（件数、キーの抽出確認）をしてから、切り替え（Web の向き先、または cluster replication／migration）は別のゲートで行う |
| current への影響 | **触る**：全 pod を作り直す＝停止。現行の copy は restore hook で `rm -rf` される（retention なし）。誤った backup を承認すると、それが現行の履歴になる | **触らない**：current はそのまま動き続ける。切り替えるまで影響なし |
| source への影響 | backup の読み取りのみ | backup の読み取りのみ |
| 必要な実装 | 承認 CR／annotation と operator の採用処理、履歴の記録を status に永続化、Case A の hook に RESTORED マーカー、置き換える copy の保持（retention）、multi-partition の partition 対応（Case C の既知の制限） | 新しい実装は最小の可能性：backupBootstrap と初回構築の承認（`first-build-approved`）は既存。ただし**理由別昇格の候補で動くことは未検証**。E2E（新クラスタ＋bootstrap＋初回構築＋全キー検証）の追加が必要。切り替え手順は R1/R4／Web 切替のゲートと一緒に決める |
| 必要な容量 | 同じクラスタ内で、置き換える現行 copy の保持（retention）＋戻す checkpoint の staging＋reserve（同じ表で retention を要求するので「追加なし」ではない） | もう一つのクラスタ分（一時的） |
| 復旧時間 | **未測定**（pod の作り直しと採用の手順の分。断定しない） | **未測定**（新クラスタの構築、検証、切り替えの分。断定しない） |
| 誤操作の影響 | 現行サービスの履歴を置き換える（取り消せない） | 新クラスタを捨てればよい |
| 規則への影響 | 承認がないかぎり今の規則のまま（承認＝明示的な例外） | 規則に例外を加えない（初回構築として扱う） |

## II の検証（CI 内の隔離した復元。実クラスタは作らない）

初回構築の承認（`first-build-approved`）は**復元の検証の代わりにしない**。
承認は「この新しいクラスタを初めて作ってよい」という意味で、復元したデータが
正しいことは示さない。CI の E2E で、次をすべて判定条件にする。

- 正常：backup から seed した新クラスタが master を持ち、**全キーと値**が
  backup 時点と一致する。**復元後の新しい書き込み**が master に受け付けられ、
  replica に複製される。
- **元のクラスタと元の backup が変わらない**（元クラスタの件数・履歴・pod、
  backup のファイル一覧と内容のハッシュを、前後で比べる）。
- 昇格させないこと（それぞれ別の試験）：
  - 不完全な backup（途中で切れた checkpoint、必要なファイルの欠け）
  - identity が一致しない backup（COPY_ID と予約キーが食い違う）
  - 別の partition の backup（partition の対応が取れないもの）
  これらでは、新クラスタの partition は master を持たず、理由をログに残す。

## 推奨（運用方針の決定はユーザーの承認待ち）

**II を標準の restore 手順の候補とし、まず上の CI 試験で確かめる。** current と
source に触らず、既存の操作で足りる可能性がある。ただし運用方針として採用するか、
実クラスタで行うかは、ユーザーが決める。I は「現行クラスタがすでに使えない」
場合の緊急手段として、承認・保持・容量を備えて別途設計する（今は実装しない）。

## 決めてほしいこと

1. 標準を II にするか。
2. I を将来の機能として残すか（残す場合、承認の形：CR か annotation か）。
3. 記録した最後の履歴を operator の status に永続化するか。これは**通常の
   failover の判断にも効く**ので、restore とは**別の設計**として扱う。その設計には
   少なくとも次を含める：status を読めない／API が Unknown のときに「記録なし（空）」
   として扱わない（＝昇格を保留する）、記録と実際の master の食い違いの扱い、
   記録を更新するタイミング（master が読めたときだけ）。
