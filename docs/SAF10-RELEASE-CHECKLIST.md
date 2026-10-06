# SAF-10 リリース判定チェックリスト（hybrid 方式）

固定リスト。行の追加・削除・区分変更はユーザーの判断でのみ行う（新しい発見は追加
してよいが、承認を止める理由を明記する）。状態の更新は、証跡（CI run と SHA、ま
たは記録済みの判断）が付いたときだけ行う。

- 対象：現行 hybrid 方式（live は op proxy、WAL は再構築・追従）での本番リリース。
  **WAL ストリーム一本化（WSTR）は今回のリリースから外す。**
- 承認条件：本番で使う範囲の未解決リスクを残さず判断すること。全 EV の一括完了は
  条件ではない。
- 判定区分：**製品不具合**／**試験不具合**／**未判定**。前提条件の失敗や再実行の成功
  だけでは区分しない。
- 担当：**C** = Claude（調査・実装・CI・記録）、**U** = ユーザー（判断・承認・本番操作）。
- 証跡はすべて `docs/safety-evidence.json` に記録する（ここは索引）。
- 現状（2026-10-06）：**本番承認なし**。PR #144 は Draft。pf-dev の master 更新は保留。

## 進め方（固定）

1. 各ブロッカーは下の「判定シート」（仮説・必要な観測・合否条件）を先に固め、
   レビューを一度に受けてから実装する。シートの問いに答えない診断は追加しない。
2. 判定に使うハーネスの論理（応答の解析、trace と GET の対応付け、応答分類、
   activation 順序の判定）は `FlareOperator/E2E/TraceMatch.lean` にあり、
   `flare_unit` で単体試験している。曖昧な入力（同じキーの反復、ポートの再利用、
   別プロセスのログ混在、trace の欠落・重複・途中切れ、正常 miss／転送失敗の
   END／明示的エラー、activation の順序違反とログ欠落）が合格にならないことを
   確認してから E2E を回す。
3. 原因調査は**単独実行**（workflow_dispatch の `suites`。push でキャンセルされない。
   checkout した commit・tree・suite を job summary と `ci-results/` に残す）。
   単独実行は全体 CI に数えない（台帳の `scope: single-suite` は
   `check_safety_evidence.py` が候補の CI 段階に数えない）。通常の PR の全体チェック
   は維持する。リリース候補が固まったら、**同一 SHA で全体検証**する。

## 本番必須

| # | 項目 | 担当 | 現状・判定 | 証跡 SHA / run |
|---|------|------|------------|----------------|
| R1 | 復旧中の欠損応答（cluster-init 29） | C 調査・修正 / U 判定承認 | **未判定** | 失敗：d47fa82 (37419299532)、f082265 (37426714842)、e2fdc27 (37438962871、trace をキー名で対応付けており判定に使えない)。100153c (37445879349)：初期同期の前提条件で失敗し、R1 の証拠なし（前提失敗の原因は未判定。37296281060 と同じ） |
| R2 | 転送失敗が END（キーなし）になる | U 方針（決定済み）/ C 実装・検証 | **方針：本番は `readUnavailableError: true`**（2026-10-06 決定）。chart の例・values の説明に反映済み。chart の既定値は変えない。pf-dev への適用は別途 | 設定 34e53ac。E2E 試験は追加済み（未実行） |
| R3 | master 切替中の activation（empty-source 4・6）→「ソース変更時に再検証」。**展開停止（2026-10-07）**：b9e0742 で empty-source 9 の安全性の失敗（DEFER された replica が空の master から再構築されコピーを失った）。R3 が原因か、以前からあったかは未確定。原則：「新 master の履歴が違う」は旧コピーを読ませない根拠であって、破棄してよい根拠ではない。保護対象のコピーを破棄する全経路が同じ保護判断を通ること。受入条件は test 2（正当な空 master）と test 9（危険な空 master）を対にする | C | 方針を採用し実装した（下記）。受入試験（empty-source の R3 試験：旧コピーの activation → 新 map 受理 → 再検証中は転送・明示的エラー → 再構築後にローカル）は追加済みで未実行。test 4 は合格、test 6 は UNDECIDED の事例を記録済み | 4：e2fdc27 (37438962871)。6：100153c (37445879349) で初めて時系列を取得。順序は R3 の基準で正しい（手で評価）。試験の失敗は map シフト行の欠落によるもので、原因は未判定。activation 点を replica 自身の「node activated」行に変更済み |
| R4 | local read guard（continuous-replication 9） | C | **未判定**（原因不明）。その後の成功では閉じない | 失敗：665bfb8 (37414948177) |
| R5 | 候補 SHA での全体 Linux CI | C | 未達（候補が未確定） | — |
| R6 | 遅延の本番要件 | U 要件 / C 測定 | **数値基準は未決**。以前の「100µs くらい」を承認済み SLO として扱わない。§13 の許容値は撤回済み | visbench 37386599657、37392841830（相対値のみ） |
| R7 | 容量・復旧評価（tmpfs）＋**同時再構築**（本番前の対応対象） | U 方針 / C 測定・実装 | 未着手。pf-dev nodes-0 7.33GB/8GB（blob 2.69GB、GC 無効）。**snapshot の固定パス共有（2026-10-07 追記）**：master の snapshot serve は固定パス `snapshot.serve.tmp` を作り直すだけで直列化していない。同時に複数の再構築が来ると、互いの転送を壊し得る。容量だけでなく再構築の正しさに関わる。直列化か要求ごとの分離、安全な後始末を実装し、同時要求を試験する（test 9 の修正とは別に扱う）。operator には同時再構築の上限がない | — |
| R8 | リリース運用（upgrade／rollback／backup restore／アラート／カナリア、pf-dev リハーサル） | U（C 補助） | 未着手。pf-dev の master 更新は保留 | — |
| R9 | 承認 | U | R1〜R8・R10 の判定を候補 SHA に対してレビューする。PR #144 のマージと本番変更は別に指示する | — |
| R10 | flared boot id の一意性（旧 D1） | C | **修正の検証は完了**（ユーザー判断 2026-10-07）。同秒・同 pid・同 random 状態の単体試験が Linux CI で名前つきで合格（旧コードでは macOS で FAIL）。E2E でも 2 pod 間と同名置換の前後で異なる値を直接観測した。**独立レビューは未実施（レビュー済みとは記録しない）** | 38e0954（修正）／ b9e0742：nix-linux 37472032909（名前つき合格）、cluster-init 37472027476（直接観測） |

## 延期可能

| # | 項目 | 担当 | 延期の理由／条件 | 現状 |
|---|------|------|------------------|------|
| D2 | map 復元後に data を持つ replica を再シードする理由 | C | R1 で欠損応答が起きないと確定すれば、可用性・効率の問題にとどまる。R1 が製品不具合なら R1 に含める | 追跡用のログあり。判定なし |
| D3 | WAL ストリーム一本化（WSTR） | C/U | 今回のリリースから外した別の開発タスク | WSTR-0 の監査・設計・測定基盤まで |
| D4 | empty-source 9 の前提条件の失敗 | C | **未判定**。原因が分かるまで試験不具合と断定しない。前提が満たされない限り、9 の製品判定は得られない | 37438962871：「先の epoch の証拠を持つ slave がいない」 |

---

## 判定シート

### R1 復旧中の欠損応答（cluster-init 29）

- **仮説**（いずれも未確認）：
  - H1：map 復元直後、replica は自分の partition を持たない（map version 0、
    Prepare）。その間の GET は partition error となり、既定設定では END
    （「キーなし」）で返る。転送失敗の偽装（R2）。
  - H2：balance 0 の replica が転送した GET を、転送先が正しく答えられなかった。
  - H3：不完全なコピーがローカル応答した。製品の安全性違反。
- **必要な観測**（100153c 以降に揃う）：GET ごとに、
  - クライアント応答（値／END／明示的エラー）；
  - 同じ接続上の決定行（local／proxy／error と理由、role／state／balance、map
    version、read guard の入力と結果）と応答行（hit／miss／unavailable と理由）；
  - GET 直前・直後の replica 状態。

  加えて、復旧中は全 pod を毎ラウンド probe する。
- **合否条件**（クライアントから見た意味で分類し、後から全件そろっても取り消さない）：
  - 不完全なコピーからのローカル応答（wrong-local）が 1 件でもあれば
    **製品不具合**（H3）。
  - サーバが読めなかったのに END で返した（masked-miss）が 1 件でもあれば
    **製品不具合（R2 の現れ）**。R2 の設定を有効にした構成で、明示的エラーに
    変わることを確認する。
  - 転送先が誤答（wrong-forwarded）なら**製品不具合**として切り分ける。
  - 明示的エラー・接続不可は可用性として集計し、別に評価する（合否に使わない）。
  - 復旧完了（replica が Active slave、ledger 空、再構築中でない）後は、全 30
    キーで値が正しく、かつ replica 自身のコピーから応答していれば合格。
  - trace の欠落・重複・途中切れで分類できない誤答は**未判定**として失敗させる。

### R2 転送失敗の END（本番方針：明示的エラー）

- **前提（確認済み）**：flared `read-unavailable-error`（動的、既定 false）。CR
  `spec.rocksdb.readUnavailableError` は operator が extra.conf に出す（chart の
  CRD スキーマにあり）。chart の values・例では未設定だった。pf-dev では未設定
  （moc2-k8s main を検索）。
  - slave が master に転送し、master が SERVER_ERROR を返した場合、slave の解析は
    その応答を拒否する（op_get の `VALUE`／`END` 以外は失敗）。転送失敗として扱われ、
    設定が有効なら slave も SERVER_ERROR を返す。
- **必要な観測**：設定 true（CR 経由）の構成で、次の 3 点。
  1. 転送が通るときは master の値が返る。
  2. replica→master を遮断すると、クライアントは `SERVER_ERROR` を受け取り、
     サーバの応答行は `result=refused reason=read_unavailable_error` になる。
  3. 本当に存在しないキーは、引き続き END（miss）で返る。
- **合否条件**：
  - 合格：1〜3 がすべて成り立ち、設定が全 pod の extra.conf に入っていること
    （empty-source の R2 試験）。
  - 製品不具合：遮断時の応答が END。
  - クライアント側：ハーネスでは明示的エラーを欠損として数えない。応答解析は
    単体試験済みで、`memcachedGet` もエラーをログに出すようにした。アプリ側
    クライアントの扱いはリリース運用（R8）で確認する。

### R3 master 切替中の activation（empty-source 4・6）

- **仮説**：完成した旧 master のコピーを、新 map の受理後に activation する経路が
  あるかもしれない。
- **必要な観測**：replica のログで、新 master を示す map を受理した行（version）、
  各「activation source check passed」（ソースと読んだ map version）、各
  「node activated」（ソース）、dump の開始と完了。加えて operator の切替行（pod
  ごとに取得し、行数を記録）、最終的な全キー・値と、それがローカル応答であること。
- **合否条件**：`TraceMatch.judgeActivation` で判定する（単体試験済み）。
  - 製品不具合：
    - 新 map を受理した後に、旧ソースを検証した、または旧コピーを
      activation した；
    - 合格した source check のない activation；
    - check の後に新しい dump が始まったコピーの activation。
  - 合格：最後の activation が新 master のコピーで、evidence が新 epoch を示し、
    値がすべて一致してローカル応答していること。
  - UNDECIDED（合格ではない）：旧コピーを新 map の受理前に activation した場合。
    切替後の扱いと read が許可されたかを追って判断する。
  - 未判定：map 受理の行や activation の行が無い場合。

#### R3 の実装（採用方針「ソース変更時に再検証する」、2026-10-06）

- flared は、コピーごとの「read ソース束縛」（ソースのノードキー・lineage・
  source epoch）を持つ。
  - 束縛するのは source check に合格した時点（activation 要求の前）。束縛は
    現在の map と同じロックの下で行い、map の master がそのソースのときだけ
    eligible、そうでなければ revalidating にする。
  - 新しい master を示す map を受理したら、その map の取り付けと**同じ書き込み
    ロックの下で** eligible を取り消す。
  - read の判断は partition map を読んだ後に束縛を読むので、新 map の下で
    判断された read が旧い適格性を見ることはない。
- 適格でない slave の read は、その時点の master に転送する。転送できなければ
  `read-unavailable-error` の設定にかかわらず明示的エラー（SERVER_ERROR）を
  返す。
- 再検証スレッドの判定（`source_eligibility.h` の純関数、単体試験 10 件）：
  - lineage と履歴が一致すれば、新しい master に束縛し直す（eligible）。
  - lineage または履歴が異なれば `needs_rebuild`。operator が既存の再構築経路
    で処理する。
  - 観測できなければコピーを保持して待つ（Unknown を理由に破棄しない）。
  - lineage を持たないバックエンド（tch）は比べるものがないため、従来どおり
    map に従う。
- 昇格の抑止：operator は昇格が起こり得るパスで各 Active slave の
  `repl_read_source_eligible` を直接読み、0 なら全昇格経路から外す。
- **方針の帰結（判断が必要）**：昇格は必ず master の epoch を進める
  （"followers of the previous history must rebuild"）。そのため**フェイル
  オーバーのたびに、その partition の他の replica は再構築される**。ローカル
  3 ノードの smoke で確認した（C は needs_rebuild、read は転送）。
- **残る隙間（判断が必要）**：
  - master の名前が変わる場合は、map 受理と同時に取り消すので隙間はない。
  - map の変化を伴わない同名での履歴変更（bulk flush、データを失った再起動など）
    は、再検証スレッドの定期確認（既定 2 s）で検出する。検出まで最大で間隔＋
    probe 時間の窓が残る。flush_all は slave にも転送されるので内容は追随する
    が、データを失った master の再起動は窓の間の read に影響し得る。

### R3-D 保護対象コピーの破棄（empty-source 9 の安全性の失敗、2026-10-07）

- **事実**：
  - b9e0742 の 2 run で、DEFER されたはずの replica が空（または 2 キー）の
    master から truncate＋dump され、コピーを失った（0/400、2/400）。この 2 run
    には operator の窓ログがない。
  - 254640b の run では、窓ログの範囲で destructive な操作は起きていない。
    replica が失ったキーは、早すぎる遮断解除の後に届いた正当な削除だった
    （前提不成立）。
- **仮説**（コード調査に基づく。独立確認前）：
  - H1（最有力）：R3 の needs_rebuild 要求が、昇格直後で master にまだデータ
    がある時点で承認された。その後 master が空になってから再構築が行われた。
    source 判定は demote 時だけで、release／reseat／copy の時点では再確認しない。
  - H2：master に 1 キーでも残っていれば判定は承認する（replica との比較なし）。
  - H3：drop 要求と R3 要求が別エントリになった（dest の表記違い）。
  - H4：判定を通らない別経路（drain、failover＋再登録、再起動の boot shift、
    zone swap、引き継ぎ時の古い map）。
  - flared 側でも、truncate／snapshot swap の前の保護は LSN の比較だけ。キー数も
    履歴も見ない。
- **必要な観測**：
  - test 9 の窓ログ（operator の全判断と replica の役割変更・truncate・dump）。
  - 前提の確定：master 0 キー、replica は取り逃した 4 キーを保持。
  - R3 要求の到着時刻（毎パス読み取り）。
- **合否条件（受入、対で判定）**：
  - test 2（正当な空 master：replica の証拠が master の履歴と一致）は再構築して
    空になる。
  - test 9（危険な空 master：証拠が以前の履歴）は再構築されず、4 キーを保持し
    続ける。
  - 経路ごとの再現試験：遅れて実行される承認済み要求、drain、再起動。
- **修正案（レビュー待ち・未実装）**：
  - flared の破壊点（truncate、snapshot swap、`hard_reset` の space-aware
    discard）の直前で、source を probe し、operator の source 判定と同じ規則を
    適用する。空、または別の履歴の source を許すのは、再構築の証拠が一致する
    ときだけ。拒否したらコピーを保持し、Prepare のまま待つ。
  - 全経路がこの一点を通るため、operator 側の判定漏れ（H1・H3・H4）も含めて
    塞がる。
  - operator 側も、release／reseat 時に再確認し、0 か非 0 かだけでなく
    replica の保持量と比べる。
  - 未決（ユーザー判断）：破損 DB の `hard_reset`、`flush_all` の replica 受理、
    epoch を送らない WAL catch-up を同じ規則の対象にするか。
  - 原則（ユーザー指示）：「新 master の履歴が違う」は旧コピーを読ませない根拠で
    あり、破棄してよい根拠ではない。

#### R3-D の実装（2026-10-07、ユーザー承認の範囲。CI 未実行）

- **H1 の扱い**：経路の存在を確認した段階。b9e0742 の損失の原因とは確定しない。
- **flared の保護点**：`copy_protection.h` の純関数（operator の
  repairSourceVerdict と同じ規則。単体試験 10 件）。判断は破壊的操作の**直前**
  に毎回評価し、キャッシュしない。source（項目数・lineage・epoch・理由）と
  受け手のコピー（項目数・lineage・epoch・再構築の証拠）に結び付ける。
  - truncate before full dump：拒否ならコピーを保持し、再構築は再試行して待つ。
  - snapshot swap：swap の直前に評価する。拒否なら受信済みの staging を消し、
    旧コピーを保持する（新コピーが揃うまで旧コピーは残る）。
  - 容量確保のための先行破棄：strict。規則に加えて source がキーを持つことを
    要求する。満たせなければ snapshot を取らず、保護された truncate 経路で
    再判断する。
  - Unknown・読み取り失敗：コピーを保持して待つ。
- **operator**：release（demote → re-seat）時に同じ判定を再評価する。defer
  なら demote のまま保持し、release しない。
- **corrupt DB**：削除しない。データディレクトリの `quarantine-<time>-<pid>` に
  退避して空で開き直す。退避できなければ何も消さず停止する（CRITICAL）。
- **replica への flush_all**：slave では拒否する（text／binary の両方。binary
  側は flush-all-enabled の設定も適用していなかったので是正）。正当な flush は
  master に送る。master の bulk rewrite で履歴が進み、replica は保護された
  再構築で追随する。**運用上の変更**：ノードごとに flush_all する手順は、
  replica への送信がエラーになる。
- **WAL catch-up**：コピーの履歴（再構築の証拠の epoch、なければ自身の
  source epoch）を送る。source が同じ履歴を名乗らない応答は適用しない。epoch
  不明なら catch-up をしない。旧版 source（epoch を送らない）とは catch-up
  せず、保護された再構築に戻る（互換の制限）。
- **受入試験**（新スイート `copy-protection`、新しいクラスタ、停止点
  `FLARE_TEST_DESTRUCTIVE_HOLD_FILE` で順序を固定）：
  - H1 再現：昇格後、master がデータを持つ間に再構築が承認され、破壊的操作の
    直前で停止する。forward を遮断して master を空にし（全削除の drop を確認、
    保持中のコピーは不変）、解放する。保護の拒否ログと、元のキー・値の全保持
    （`dump` で replica 自身のコピーを読む）を確認する。90 s 後も保持している
    ことで test 9 の期待も兼ねる。
  - Unknown：停止点で source を読めなくして解放する。truncate なし、キーの欠落
    なしを確認し、source が読めるようになったら収束する。
  - test 2（正当な空 master）は empty-source のまま。
- **残る制限**：
  - full dump 経路は truncate の後に dump するので、「新コピーを検証するまで
    旧コピーを保持」にはなっていない。判断は truncate の直前で、dump 中の
    source の履歴変更は dump の終わりの identity 照合で検出するが、その時点で
    コピーはもうない。
  - snapshot swap の保護は E2E では未検証（E2E は snapshot を無効化して
    truncate 経路を試験している）。
  - empty-source test 9 は、R3 が昇格直後に旧履歴の replica を再構築するため、
    前提に到達しない（期待は copy-protection の H1 試験で検証する）。

#### R3-D の残件（ユーザー指示 2026-10-07。本番前に必須）

1. **full dump 経路**：記録は「破棄前の再確認を実装・検証した」にとどめる
   （「再構築で良いコピーを失わない」とは記録しない）。直前の確認の後に
   source が変わると旧コピーを失い得る。本番前に残存リスクの扱いを決める。
   候補はステージングへのコピー、容量不足時は停止して明示的な承認を求める方式。
2. **snapshot 経路の試験**：swap と、容量確保のための先行破棄は E2E で未検証。
   R7 の固定パス問題の修正と合わせて、両境界で source が変わる／Unknown に
   なる場合も旧コピーを保持することを試験する。
3. **quarantine の後の扱い**：
   - 隔離後の空 DB が、健全な空コピーとして read・昇格・修復元に使われない
     ことを確認する。
   - tmpfs では隔離しても容量は空かないので、隔離領域を含めて容量を判定する。
   - 再起動のたびに隔離を繰り返さない。
4. **互換性の変更（リリースノートと運用手順に残す）**：
   - replica への flush_all 拒否は意図的な互換性変更。
   - 旧版 source との WAL catch-up を止めた。混在バージョンで、保護された
     再構築が完了することまで確認する。
5. **旧 test 9**：削除しない。過去の失敗（b9e0742 の 0/400・2/400、
   254640b の前提不成立）と、新しい H1 試験（copy-protection）との対応を
   残す。到達できない前提を無理に維持する必要はない。

### R4 local read guard（continuous-replication 9）

- **仮説**：未特定。配送を遮断している間に replica の balance が変わった（map が
  届いた、または別経路で変わった）。
- **必要な観測**：遮断の前・中・後の、replica 自身の map version と balance
  （今回の「node map accepted」行）。operator の broadcast 版とその配送先。read
  trace による各 GET の判断。
- **合否条件**：
  - 製品不具合：遮断中に map の変化が観測されたら、遮断が効いていない経路を特定し、
    その経路で read guard が守られているかを判定する。
  - 試験不具合：変化が試験自身の操作によるものと示せた場合のみ。
  - それ以外は**未判定**。

### R10 boot id の一意性（旧 D1、本番必須）

- **事実**：`reconstruction_boot_id = time<<32 ^ pid<<16 ^ random()`。random() は
  一度もシードされず、コンテナでは pid が繰り返す。37438962871 では、同じ秒に
  起動した 2 つの pod が同じ値を持っていた。
- **比較箇所**（すべてノードキーで比較しており、Pod UID とは組にしていない）：
  - FollowEvidence.markProcessChanges：前回との比較。
  - ReplicaRepair：reseat 時の boot と完了の比較。
  - Main：SyncEvidence の activation 直前の再読み込み（regEpoch の比較もある）。
  - ReplicaRepair.observe：drop counter を master の boot に結び付ける。
- **衝突で別プロセスの証拠を受理する経路**：同じ pod（同名 Pod の置換を含む）で、
  同じ秒・同じ pid の再起動が起きると値が一致する。
  - drop counter は、新プロセスの値が旧値以下なら「変化なし／増分のみ」となり、
    修理要求が出ない、または過少になる。
  - activation 前の boot 再読み込みは、プロセスの入れ替わりを見逃す（regEpoch の
    再登録が遅れた場合）。
  - follow の processChanged が立たず、1 回の読みで read／promote の判断に入る。
- **修正**（未 push）：
  - `/dev/urandom` 由来の値にする（失敗時はナノ秒時刻・pid・アドレスを混ぜる）。
  - 62 bit にマスクし、JSON／k8s の整数範囲に収める。
  - 単体試験：同じ秒・同じ pid・同じ random() 状態で作った 3 つの値が異なること。
    旧コードでは FAIL、新コードでは PASS（macOS ローカル）。
- **合否条件**：Linux CI でその単体試験が通り、boot を使う既存の E2E
  （repair-ledger、prepare-evidence、follow 系）が回帰しないこと。operator 側で
  Pod UID と組にするかどうかは、この修正の後でも必要かを別に判断する（現時点では
  不要と考えるが、未承認）。

## 判定の記録

| 日付 | 項目 | 判定 | SHA / run | 根拠 |
|------|------|------|-----------|------|
| 2026-10-06 | R3 test 4 | 合格（時系列） | e2fdc27 / 37438962871 | 新 map 受理後に旧コピーは STOPPED。新 master のコピーで check→activation。400 キーの値が一致しローカル応答。operator の切替時刻は未取得 |
| 2026-10-06 | R10 | 製品不具合（修正済み、CI 未実行） | — | 上の判定シート |
| 2026-10-06 | R3 test 6 | 順序は正しい（手評価）。試験の失敗は未判定 | 100153c / 37445879349 | v…608 受理 → 旧コピー STOPPED → n1 から dump → v…622 で check → n1 で activation。map シフト行は窓の外 |
| 2026-10-06 | R1 | 未判定（2 回合格、ただし H3 は未検証） | cd1d9b0 / 37451914041（全体）・37451911169（単独） | 復旧中の probe はすべて正答。ただし replica の balance は 0 で、読み取りはすべて方針どおり master へ転送された。過去の失敗（replica へ読み取りを振った状態で再シード）は再現していない。次は読み取りを replica へ振った状態で復旧中を probe する |
| 2026-10-06 | R2 | 未判定（試験不具合：ログで確認） | cd1d9b0 / 両 run | 遮断中、転送の再接続（0.5 s × 8 × 最大 4 回）がクライアントの 5 s より長く、遮断を解いた後に転送が成功した。失敗時にクライアントが受け取る応答は未観測。可用性の finding：RST でも失敗まで約 16〜20 s、proxy 接続には connect の期限がない |
| 2026-10-06 | R3 test 6 | 単独 run は合格。全体 run は UNDECIDED | cd1d9b0 / 37451907614・37451914041 | 全体 run では、旧 master n0 のコピーを v…606 で check して activation し、その後 v…613（n1）を受理した。受理後の再検証・再構築はない。balance 0 なので、この構成ではローカル read なし。node activated は activation 要求の成功の証拠であり、Active map の受理や read 開始の証明ではない |
| 2026-10-06 | R10 | 未完了 | cd1d9b0 | 全体 CI の他スイートは回帰なし。**訂正**：cutter の単体試験は Linux CI でも `make check` で実行されている（nix-linux の RocksDB ビルドで `PASS: run-tests.sh`、test_stats_reconstruction のコンパイル・リンクを確認）。ただし試験名ごとの結果はログに出ていなかったため、check phase で名前つきの結果を出すようにした。同名 Pod の置換と 2 pod 間の boot id は cluster-init 29 で直接比較する（未実行） |
