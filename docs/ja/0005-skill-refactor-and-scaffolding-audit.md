---
commits:
  - d35a612
date: 2026-04-27
scope:
  - .claude/commands/continue.md (deleted)
  - .claude/skills/continue/SKILL.md (new)
  - .claude/skills/code-learning-doc/SKILL.md (slimmed 318 → 93)
  - .claude/skills/code-learning-doc/TEMPLATE.md (new, separated)
  - .claude/skills/audit-scaffolding/SKILL.md (new)
  - .claude/skills/audit-scaffolding/CHECKS.md (new)
  - CLAUDE.md (slimmed ~150 → 94)
  - .dev/ROADMAP.md (§11.6 split, §11.7 new, §12.2 / §12.4 deduplicated)
  - .dev/decisions/README.md
  - .dev/handover.md
  - test/run_all.sh (zone_check --gate added)
related:
  - 005_claude_code_slash_inventory.md (調査ベースの一次資料)
  - ROADMAP §11.6 (Active / Planned 分割)
  - ROADMAP §11.7 (Periodic scaffolding audit 新設)
---

# 0005 — Skill リファクタと scaffolding 自己評価フェーズの導入

Claude Code 2026-04 inventory を読み、現状の scaffolding を 4 軸
(deprecated / 重複 / 長大 / 未自動化) で監査して構造的にリファクタ。
さらに「scaffolding 自体の腐敗を周期的に検出する skill」を新設し、
自律ループに評価フェーズを組み込んだ。

---

## 背景 (Background)

### Inventory からの 1 次情報

`/Users/shota.508/Dropbox/LifeNote/knowledge/005_claude_code_slash_inventory.md`
を読んだら **重要な事実** が判明:

> `.claude/commands/*.md` は **officially deprecated**
> ([anthropics/claude-code#37447](https://github.com/anthropics/claude-code/issues/37447))。
> 新規作成は `.claude/skills/<name>/SKILL.md` で書く。

直前のイテレーションで作った `.claude/commands/continue.md` は **既に
deprecated** な仕組みだった。後方互換は維持されているが、新プロジェクトで
わざわざ deprecated 仕組みを採るのは loop 設計として不健全。

### 4 つの腐敗パターン

実物の scaffolding を見直して気付いた問題:

1. **Deprecated 仕組みの採用**: 上記 commands/ 問題
2. **冗長な重複**: `code-learning-doc` の Rule 1/2 が SKILL.md / CLAUDE.md /
   ROADMAP §12.2 の 3 ヶ所に full text で書かれていた → drift 必至
3. **長大化**: `code-learning-doc/SKILL.md` が 318 行。雛形 (template) を
   含んでいるため。skill body は短く、補助ファイルに分離すべき
4. **未自動化**: `scripts/zone_check.sh` を作ったのに `test/run_all.sh` から
   呼んでいない → 手動実行頼み → 忘却リスク

### 「scaffolding 自体を audit する」という抜けていた視点

これまでの commits 1-6 は「コードの規律」と「doc の規律」を整備したが、
「scaffolding 自体の規律」(陳腐化チェック / drift チェック / dead link
チェック) は無かった。LLM 主導開発で最も腐りやすいのは scaffolding そのもの
なので、ここに自動 audit を入れる必要がある。

業界知見 (一般的 docs hygiene + Anthropic skill 設計指針より):

| 腐敗パターン       | 例                                                          |
|--------------------|-------------------------------------------------------------|
| **Staleness**      | 言及内容が現状コードと不一致 (削除されたファイルを参照等)    |
| **Bloat**          | 1 ファイル過大、重複セクション、冗長記述                    |
| **Lies**           | "we always X" のような absolute 主張が現実と異なる          |
| **False positive** | gate / rule の trigger が想定外場面で発火                   |
| **Dead links**     | ファイル・URL・§ 番号・ADR 番号がリンク切れ                |
| **Drift**          | 同じ事実が複数 file にあって乖離し始めている              |

これらを **周期的に機械的にチェック** する仕組みが要る。

---

## やったこと (What)

### d35a612 — Scaffolding 全面リファクタ (1 source commit)

Inventory 文書の知見と腐敗パターン分析を踏まえた構造的整理。
ゲート的には source-bearing にカウントされない (src/ / build / ADR を
触らない) ので本ファイルは voluntary doc。

#### (1) `/continue` を skill 化 (deprecated → recommended)

```
削除: .claude/commands/continue.md
新規: .claude/skills/continue/SKILL.md
```

frontmatter description で「続けて」「resume」「pick up」phrases に
auto-trigger する形に。`.claude/commands/` ディレクトリ自体も削除。

#### (2) `code-learning-doc` を SKILL + TEMPLATE に分離

```
.claude/skills/code-learning-doc/
├── SKILL.md      (93 行: policy + workflow + canonical gate rule)
└── TEMPLATE.md   (77 行: docs/ja/NNNN-*.md の雛形のみ)
```

公式仕様: skill ディレクトリには補助ファイル (template / script) を同梱可。
Skill 本体は薄く、雛形は別ファイルにすることで:
- skill auto-load 時のコンテキスト消費を削減 (TEMPLATE.md は明示参照時のみ)
- 雛形の `cp` で利用するワークフローが綺麗

#### (3) `audit-scaffolding` skill 新設 (本イテレーションの目玉)

```
.claude/skills/audit-scaffolding/
├── SKILL.md     (75 行: 起動条件、procedure、output format)
└── CHECKS.md    (201 行: A/B/C/D/E カテゴリ別の具体チェック項目)
```

5 カテゴリ × 多項目のチェックリスト:
- **A. Staleness**: A1 ROADMAP §5 vs filesystem / A2 §9 phase tracker
  vs handover / A3 [x] task SHA 実在 / A4 ja doc front matter SHA 実在 /
  A5 handover の "Last paired commit" が git log と一致 / A6 backticked
  パス参照の dead link
- **B. Bloat**: B1 ファイル行数 vs soft limit / B2 同じ事実が複数箇所
  (`grep -lF 'source-bearing'` 等) で重複 = drift 候補
- **C. Lies**: C1 "Active" gate が実際 wired か / C2 reference clones
  実在 / C3 README の build/test 主張
- **D. False positives**: D1 rules の paths frontmatter が実 file と
  match / D2 gate の `is_source_path` が意図通り / D3 skill description
  が想定通り
- **E. Coverage**: E1 Phase task と実 file の対応 / E2 quality gate の
  owner

severity は **block / soon / watch** の 3 段階。output は markdown
レポート (`private/audit-YYYY-MM-DD.md` に保存も可)。

#### (4) CLAUDE.md slim化 (~150 → 94 行)

- "Iteration loop" 節 (40 行) を skill `continue` に統合 → CLAUDE.md
  からは 1 段落 + 参照のみ
- "Commit pairing" 節 (20 行) を skill `code-learning-doc` に統合 →
  CLAUDE.md からは 1 段落 + 参照のみ
- "Skills" 節を新設 (3 skills の 1 行説明)
- 結果: 常時ロード負担を 1/3 程度に削減

#### (5) ROADMAP §11.6 split + §11.7 新設

- §11.6 を Active / Planned の **2 表に分割** (Status 列削除で簡素化)
- §11.7 「Periodic scaffolding audit」新設 → audit-scaffolding skill 参照
- §12.2 を「skill code-learning-doc が canonical」と参照のみの 3 行に
- §12.4 を「skill continue が canonical」と参照のみの 3 行に

#### (6) `test/run_all.sh` に `zone_check --gate` 統合

```bash
echo "==> 1. zig build test"
zig build test
echo "==> 2. zone_check --gate"
bash scripts/zone_check.sh --gate
```

→ §11.6 gate #2 が Planned から Active に昇格 (Phase 2.20 を待たず)。

#### (7) handover.md / decisions/README.md 同期

旧 `.claude/commands/continue.md` 参照を skill に置き換え。pairing
ルール表現を「次の commit で必ず doc」から「次の doc commit で必ず
SHA を含める」に正確化 (n:1 緩和を反映)。

---

## コード (Snapshot)

### Skill frontmatter のパターン

```yaml
---
name: continue
description: Resume autonomous work on cw-from-scratch. Trigger when the user says 続けて, "resume", "pick up where we left off", "/continue", or starts a fresh session expecting prior context. Reads handover, finds next task, summarises, waits for go.
---
```

description が長く具体的なほど auto-trigger 精度が上がる。「続けて」を
含めることで日本語 phrase でも発火。

### audit-scaffolding/CHECKS.md (チェック A4 抜粋)

```sh
# A4. ja doc front-matter `commits:` SHAs all exist
for f in docs/ja/[0-9][0-9][0-9][0-9]-*.md; do
  python3 -c "import re,sys
fm = open('$f').read().split('---')[1]
for m in re.finditer(r'^\s*-\s+(\S+)', fm, re.M):
    print('$f', m.group(1))" \
  | while read file sha; do
      git rev-parse --verify "$sha" >/dev/null 2>&1 || echo "MISSING: $file → $sha"
    done
done
```

シェル + Python 1 行で各 ja doc の `commits:` リストを抽出 → `git
rev-parse` で実在検証。dead SHA references を機械的に検出する。

### CLAUDE.md "Skills" 節 (新規、参照だけ)

```markdown
## Skills (the runnable procedures)

- **`code-learning-doc`** — when to write docs/ja/NNNN-*.md, the
  template, and the gate's two rules.
- **`continue`** — resume procedure (per-task TDD loop included).
- **`audit-scaffolding`** — periodic audit for staleness, bloat,
  lies, false positives.
```

CLAUDE.md は「**何があるか**」だけ示す。詳細は skill が auto-load
されたときに展開される。これが skill 機構の正しい使い方。

### ファイルサイズ before/after

```
                                          before  after  delta
CLAUDE.md                                  ~150     94   -56
.claude/skills/code-learning-doc/SKILL.md   318     93   -225
.claude/skills/code-learning-doc/TEMPLATE   (in)    77   +77
.claude/skills/continue/SKILL.md            (n/a)   57   +57  ← 新規
.claude/skills/audit-scaffolding/SKILL      (n/a)   75   +75  ← 新規
.claude/skills/audit-scaffolding/CHECKS     (n/a)  201  +201  ← 新規
.claude/commands/continue.md                  29     0   -29  (削除)
test/run_all.sh                               37    37     0  (zone_check 追加で +5 程度)
```

正味で **+100 行** だが、内訳は「常時ロードされない (auto-load 時のみ)」
ファイルへの移動 + 新スキル。常時ロード CLAUDE.md は -56 行 = コンテキスト
消費が確実に減る。

---

## なぜ (Why)

### 4 層の Claude Code リソースモデルを正しく使う

inventory 文書から:

| 層                             | trigger 性質                          | 用途                                  |
|-------------------------------|---------------------------------------|---------------------------------------|
| `CLAUDE.md`                    | 常時ロード (毎セッション)              | 全体ルール、Identity、原則            |
| `.claude/rules/X.md`           | path-matched auto-load (frontmatter `paths:`) | 特定ファイル編集時のリマインダ |
| `.claude/skills/X/SKILL.md`    | description-matched auto-trigger      | 特定アクション (skill 機構)           |
| skill 内補助ファイル            | skill 起動後に明示参照               | 雛形・チェックリスト・スクリプト    |

**従来は CLAUDE.md と rules しか活用していなかった**。skill 機構を
正しく使えば常時ロード負担を skill 側に逃がせる。`code-learning-doc`
の Rule 1/2 は CLAUDE.md にもあったが、本来 skill が canonical で十分。

### Soft limit を採用する根拠

- **CLAUDE.md ~100 行**: 毎セッション全文ロードされるため、肥大化は
  コンテキスト窓を直撃する。100 行ぐらいが「project memory として要点
  のみ」の上限
- **`.claude/rules/*.md` ~200 行**: 編集時 auto-load なのでセッション
  全体ではなく特定ファイル編集時のみコスト。広めの上限
- **`.claude/skills/*/SKILL.md` ~150 行**: trigger 時のみロード。
  description で取捨選択されるため、広い領域カバーする skill は内容を
  サブファイルに分離するのが綺麗
- **`.dev/ROADMAP.md` ~1500 行**: reference doc (必要時のみ Read)。
  大きくて OK

これらの soft limit を audit-scaffolding/CHECKS.md B1 に明文化。
"watch (80%)" → "soon (over)" → "block (規模次第)" の 3 段階で警告。

### audit-scaffolding を **skill** にする判断

候補は 3 つあった:
1. **CLAUDE.md に audit 手順を直書き** → 常時ロード負担、しかも実行は
   稀 → 不釣合い
2. **CLI script (`scripts/audit.sh`)** → 機械的部分は OK だが、判断
   (severity 振り分け、修正優先順位) は LLM 介入が必要
3. **Skill** → 起動条件 description で trigger、機械チェックは Bash
   script (CHECKS.md の例) で自動化、LLM が結果を解釈してレポート
   生成 → 最適

→ skill に。CHECKS.md という補助ファイルパターンは公式仕様準拠 +
LLM コンテキストを 75 行 SKILL に抑えつつ詳細は 201 行 CHECKS に
逃せる。

### `test/run_all.sh` に zone_check 統合

「Phase 2.20 で wire する」と書いていたが、現状でも空 src/ で 0
violations を返すので **今組み込んでもコストゼロ**。Phase 2 開始時に
「あ、まだ wire してない」と気付かないリスクを排除。Active gate に
昇格。

---

## 確認 (Try it)

### サイズチェック

```sh
$ wc -l CLAUDE.md .claude/skills/*/SKILL.md
      94 CLAUDE.md
      75 .claude/skills/audit-scaffolding/SKILL.md
      93 .claude/skills/code-learning-doc/SKILL.md
      57 .claude/skills/continue/SKILL.md
```

すべて soft limit 内。

### test runner verification

```sh
$ bash test/run_all.sh
==> 1. zig build test
    OK
==> 2. zone_check --gate
    OK

All test suites passed.
```

zone_check が自動実行され、空 src/ で 0 violations。

### Skill 一覧 (`.claude/skills/`)

```sh
$ ls .claude/skills/
audit-scaffolding/
code-learning-doc/
continue/
```

3 skills、`.claude/commands/` は完全削除。

### audit-scaffolding skill の試運転 (将来 Phase 1 終了時)

```
ユーザ: /audit-scaffolding
Claude:
  Reading CHECKS.md...
  A1 ROADMAP §5 vs filesystem ........... 0 findings
  A2 §9 phase table vs handover .......... 0 findings
  A3 [x] task SHAs exist ................. 1.0 → 116b874 ✓
  A4 ja doc commits SHAs exist ........... 5/5 ✓
  ...
  B1 file sizes vs soft limit ............ all OK
  B2 duplicated facts .................... 0 (after refactor)
  ...
  C1 Active gates wired .................. 3/3 ✓
  ...

  ## summary
  No block findings. 1 soon: ROADMAP §11.6 has 16 Planned gates;
  none are activatable yet but will be reviewed at Phase 2 start.

  Read full report: <stdout>
```

(将来の出力イメージ)

---

## 学び (Takeaway)

### Claude Code 2026 のベストプラクティス

- **`.claude/commands/` は使わない** (deprecated #37447)。新規は必ず
  `.claude/skills/<name>/SKILL.md`
- **Skill 補助ファイル**: SKILL.md は薄く (≤150 行)、template/checklist/
  script は同ディレクトリの別ファイル (`TEMPLATE.md`, `CHECKS.md` など)
  に分離。skill 機構は補助ファイルを認識・参照可能
- **Description は trigger 性能を決める**: "Trigger when user says X"
  のように具体的に書く。日本語 phrase も description に含めると日本語
  発話で発火する
- **`disable-model-invocation: true`** で「ユーザ明示時のみ」起動
  (zwasm の `release` skill のような重い操作向け)。今回の 3 skill は
  すべて auto-trigger 可で OK

### Scaffolding 設計の知識

- **CLAUDE.md は "what / where" で十分**: "how" は skill に任せる。
  常時ロードコストの観点で正しい分割
- **canonical 1 + pointers N**: 同じ事実を N ヶ所に書くと drift する。
  必ず 1 ヶ所を canonical (skill 推奨) にし、他は 1-3 行の pointer
  だけ持つ。今回は Rule 1/2 を skill canonical にした
- **soft limit は明文化**: 「短く保つ」だけだと曖昧。`CLAUDE.md ~100`
  `SKILL.md ~150` のような数値で、audit-scaffolding が機械検出可能に
- **rule files の生死は paths frontmatter で**: rules がマッチする
  パスが repo に存在しない時、その rule は永久に load されない =
  dead rule。audit D1 でこれを検出
- **audit を「成果」にする**: 直接的な機能追加 (1 行コード) と並んで
  scaffolding audit も commits の 1 単位として扱う。これで「気付いた
  ら drift してた」を防げる

### 自律ループへの評価フェーズ組み込み (本イテレーションの中核)

**周期**: Phase boundary / 10 ja docs / pre-release / explicit
**手段**: skill `audit-scaffolding` を invoke
**チェック**: CHECKS.md A-E カテゴリ (5 軸 × 多項目)
**output**: markdown レポート (severity 3 段階)
**修正**: ユーザ承認後に follow-up commits で実施 (audit 自体は
non-destructive)

これで **自律ループ = 実装 + doc + 周期評価** の 3 構成が成立する。
従来の「実装 + doc」だけでは scaffolding rot に気付けないが、これに
audit を加えることで **rot の早期発見と修正** がループに組み込まれた。
これは v1 / 旧 FromScratch にもなかった構造的改善。

### Bash + Python の相性

`audit-scaffolding/CHECKS.md` の各チェックは:
- 単純な存在確認: `test -e`, `grep -lF`
- リスト処理: `find`, `wc -l`, `sort -u`
- frontmatter parse: 1 行 python heredoc (PyYAML 不要、re で十分)

「Bash で 80% / Python で 20%」のハイブリッドが、依存ゼロで実行できて
audit 用途に最適。jq / yq に依存させると flake.nix の dev shell に
余計な package が増える。
