---
commit: TBD
date: 2026-04-27
scope:
  - .claude/rules/zone_deps.md
  - .claude/rules/zig_tips.md
  - .claude/rules/compat_tiers.md
  - .dev/ROADMAP.md
  - .dev/decisions/README.md
  - .dev/decisions/0000-template.md
  - .dev/handover.md
  - .dev/known_issues.md
  - .dev/compat_tiers.yaml
  - .dev/concurrency_design.md
  - .dev/wasm_strategy.md
  - scripts/zone_check.sh
  - test/run_all.sh
related:
  - ROADMAP §11.6 (Quality gate timeline)
  - ROADMAP §15.1 (References)
  - private/2026-04-27_strategic_review/02_plan_review.md (G1-G5)
  - private/2026-04-27_strategic_review/03_ecosystem_and_architecture.md
---

# 0002 — 立ち上げ期の監査と足回り追補

bootstrap commit (`116b874`) を、自分で書いた戦略レビュー
(`private/2026-04-27_strategic_review/`) と参照プロジェクト (v1 / 旧 FromScratch /
v1 zwasm) と引き合わせ、**自律開発が走り出してからでは「忘れる」「ブレる」**
要素を Phase 1 着手前に塞ぐ。

---

## 背景 (Background)

### なぜいま監査か

bootstrap commit は速度優先で出した。結果、**戦略レビュー §G1〜G5 で
「Phase 3 までに入れるべき」と書いた項目** が roadmap への言及だけで
実体ファイルが無いまま積み残された。LLM 主導の自律開発は走り出すと
「無いものは無いまま気付かれない」傾向が強く、Phase 1 が動き出してからの
追加は割り込みコストが高い。**Day 0 のいま** 入れる。

### Claude Code 自律開発における 4 種のドキュメント

整理しておく:

1. **常時ロード** = `CLAUDE.md` (project memory): セッション開始時に必ず読まれる。
   全体ルール、Identity / Context、言語ポリシー、build / test コマンド。
2. **path-matched 自動ロード** = `.claude/rules/*.md` (frontmatter `paths:` で指定):
   そのパスのファイルを読み書きする時だけロードされる。zone deps / zig tips /
   compat tiers のように **編集する時だけ知っていれば良い** ルールはこちらに置く。
   CLAUDE.md を肥大させずに済む。
3. **ロードオンデマンド** = skill (`.claude/skills/*/SKILL.md`): description が
   トリガ条件と一致した時にロード。`code-learning-doc` skill のように
   **特定アクション** に紐づくものはこちら。
4. **手動参照** = `.dev/ROADMAP.md` 等: Claude が必要に応じて Read する。
   詳細プラン / ADR / handover メモ。

bootstrap では (1) と (3) しか作らず、(2) を見落としていた。これは旧 FromScratch も
v1 もちゃんと持っていたパターン。

### 「将来必要だが今は動かない」ゲートの記録問題

例: dual backend `--compare` (Phase 8)、x86_64 cross gate (Phase 1.12+)、
upstream test 移植ルール (Phase 11)、JIT go/no-go ADR (Phase 17 末)。
これらは **Phase 1 のコードだけ書いていると忘れる**。ROADMAP §9 (Phase 計画) には
1 行で出てくるが、横串で見ないと「全 Phase で何を引き継いでいるか」が
分からない。**1 つの table に集約**しておく必要がある。

---

## やったこと (What)

13 ファイル追加 + 1 ファイル削除 + ROADMAP 更新。

**`.claude/rules/`** (path-matched 自動ロード規則):
- 新規: `zone_deps.md` — src/**/*.zig 編集時に zone 規則を強制
- 新規: `zig_tips.md` — src/**/*.zig 編集時に Zig 0.16 idiom リマインダ
- 新規: `compat_tiers.md` — src/lang/** または compat_tiers.yaml 編集時に Tier 制を強制

**`.dev/decisions/`** (ADR インフラ):
- 新規: `README.md` — ADR 命名規則 / 必須セクション / lifecycle
- 新規: `0000-template.md` — テンプレート (絶対消さない)

**`.dev/`** (運用ドキュメント):
- 新規: `handover.md` — セッション間引き継ぎ (現状 = pre-Phase-1, bootstrap done)
- 新規: `known_issues.md` — P0-P3 priority 構造 (現在すべて空)
- 新規: `compat_tiers.yaml` — namespace 単位 Tier の source of truth (ROADMAP §6.2 から具体化)
- 新規: `concurrency_design.md` — Phase 15 までに「忘れない」ための pre-deep-dive
- 新規: `wasm_strategy.md` — Phase 14 / 19 までに「ブレない」ための pre-deep-dive (ハイブリッド C 案を仮決め)

**`scripts/`** (ゲート / 検査):
- 新規: `zone_check.sh` — 旧 FromScratch から移植 + 修正 (空 src/ で安全に exit 0、`grep` 無マッチで失敗しない bug fix)

**`test/`**:
- 新規: `run_all.sh` — 統一テストランナー (今は `zig build test` のみ。Phase ごとに suite を追記)

**ROADMAP.md** 更新:
- §5 から `.editorconfig` 削除、`.claude/rules/`, `.dev/concurrency_design.md` /
  `.dev/wasm_strategy.md` を追加
- **§11.6 Quality gate timeline (active + future) 新規追加** ← 16 個のゲートを 1 表に
- §15.1 References を追加分で更新
- §17 改訂履歴に audit pass entry

**削除**:
- `.editorconfig` (Emacs 開発、format は将来 pre-commit script に集約予定。
  §11.6 の gate #4 として記録)

---

## コード (Snapshot)

### `.claude/rules/zone_deps.md` (frontmatter 部)

```yaml
---
paths:
  - "src/**/*.zig"
  - "modules/**/*.zig"
  - "build.zig"
---
```

`paths:` に列挙したパスのファイルを Claude が edit/read する時に **自動的に**
このファイルがロードされる。CLAUDE.md と違って常時ロードではないので、
プロジェクトメモリの圧迫がない。

### `scripts/zone_check.sh` (バグ修正部分)

旧 FromScratch から持ち込んで早速踏んだ落とし穴: `set -euo pipefail` と
`grep` の組み合わせ。

```bash
# 修正前 (bug): grep が無マッチ → exit 1 → pipefail で全体 exit 1
awk '/^test "/{exit} {print NR ":" $0}' "$file" \
    | grep -E '@import\("[^"]+\.zig"\)' \
    | while IFS=: read -r lineno content; do

# 修正後: grep の non-zero を { ; } で localize し || true で吸収
awk '/^test "/{exit} {print NR ":" $0}' "$file" \
    | { grep -E '@import\("[^"]+\.zig"\)' || true; } \
    | while IFS=: read -r lineno content; do
```

「無マッチは正常」のケースで `set -e` + `grep` の組み合わせは要注意。
`{ cmd || true; }` で囲むのが定番処方箋。

### `.dev/compat_tiers.yaml` (Tier 表のサンプル)

```yaml
clojure.core:           { tier: A, phase: 14 }
clojure.string:         { tier: A, phase: 10 }
clojure.spec.alpha:     { tier: B, phase: 14 }
clojure.core.async:     { tier: C, phase: 15 }
java.lang.String:       { tier: D, phase: -  }
java.io.File:           { tier: B, phase: 14 }
```

`phase` は「いつまでにこの Tier に到達するか」。第三者ライブラリは ADR
経由で追加、空欄のまま起動。

### `.dev/ROADMAP.md` §11.6 Quality gate timeline (抜粋)

```
| # | Gate                              | Status                       | Prepare by  |
|---|-----------------------------------|------------------------------|-------------|
| 1 | Learning-doc gate                 | Active                        | —          |
| 2 | Zone-dependency check             | Active (info, 0 violations)   | Phase 2.20 |
| 3 | zig build test                    | Active                        | —          |
| 4 | zig fmt --check src/              | Planned                       | Phase 1    |
| 5 | x86_64 cross gate                 | Planned                       | Phase 1.12 |
| 6 | Dual-backend --compare            | Planned                       | Phase 8    |
| 7 | Bench regression ≤ 1.2x           | Planned                       | Phase 8    |
| 8 | Tier-A upstream test green        | Planned                       | Phase 11   |
| 9 | Tier-change ADR present           | Planned                       | Phase 9    |
|10 | compat_tiers.yaml complete        | Planned                       | Phase 14   |
|11 | GC root coverage                  | Planned                       | Phase 5    |
|12 | Bytecode cache versioning         | Planned                       | Phase 12   |
|13 | JIT go/no-go ADR                  | Planned                       | Phase 17 end|
|14 | Wasm Component build green        | Planned                       | Phase 14   |
|15 | WIT auto-binding correctness      | Planned                       | Phase 19   |
|16 | nREPL operation parity            | Planned                       | Phase 14   |
```

---

## なぜ (Why)

### 5 つの設計判断

**1. `.editorconfig` を削除 (Emacs 開発前提)**
- 採用理由: ユーザは Emacs。`.editorconfig` を読むエディタ向けの設定であり、
  Emacs では `editorconfig.el` がないと無視される (デフォルトでは入っていない)。
  プロジェクトに置いておくと「設定がある = 守られている」と誤認させる毒
- 代替: format は `zig fmt` を pre-commit gate に入れる方が確実。今は src/main.zig
  しかなく gate を入れる意味が薄いので、ROADMAP §11.6 #4 として「Phase 1 で
  src/ が育ったら gate 投入」と placeholder

**2. `.claude/rules/` を path-matched 自動ロードで作る**
- 採用理由: zone 規則 / Zig 0.16 idiom / Tier 規則 はそれぞれ **触るときだけ
  必要な知識**。CLAUDE.md に全部書くと project memory が肥大して逆に
  読まれにくくなる。frontmatter `paths:` でファイル種別ごとに必要時のみ
  ロードする方式が、旧 FromScratch でも v1 でも採用されていた
- 却下案 1: 全部 CLAUDE.md に集約 → 数百行になり常時ロード負担増
- 却下案 2: ROADMAP に集約のみ → 編集時に Claude が自発的に読みに行く保証なし
- 採用形: 重要ルール 3 本 (zone / zig tips / tiers) を `.claude/rules/` に分離

**3. `.dev/decisions/` を Day 0 から用意 (空でも)**
- 採用理由: ADR は **判断の事後記録**。後で書こうと思うと書かない。template と
  README を Day 0 に置いておけば、Phase 1 の最初の判断 (例: heap type slot 配置)
  が ADR 0001 として自然に残る
- 却下案: ADR は不要、ROADMAP の改訂履歴で十分 → 重要判断と細かい変更が混ざる

**4. `concurrency_design.md` / `wasm_strategy.md` を pre-deep-dive として独立**
- 採用理由: 戦略レビュー §G1 / §G2 が「Phase 3 までに書け」と明示。**ROADMAP §7 / §8 に
  概要は入っているが、設計の根拠 / 却下案 / open question までは入りきらない**。
  別ファイルで深掘りしておくと、Phase 15 / Phase 19 が来た時に「あ、当時
  こう考えていたのか」が即座に蘇る
- 却下案 1: ROADMAP §7 / §8 を厚くする → 1 本のファイルが 1500 行を超えて読みにくくなる
- 却下案 2: ADR にする → ADR は決定の単位、概念設計の deep dive とは粒度が違う

**5. ROADMAP に「Quality gate timeline」表を追加**
- 採用理由: ユーザの指示「将来そこに達した段階で用意しなければならないやつも、
  ロードマップに配置しておかないと忘れそう」に直接対応。
  Phase ごとの task list にバラバラに書くより、**1 個の表で全 gate を見渡す** ほうが
  「自律開発で何度も同じ忘却を繰り返す」を防げる
- 形式: Active / Planned + Prepare-by phase。Planned が Active に昇格する時に
  table 自体を更新するルール

### ROADMAP / 原則との対応

- §2 P4 (アドホック対応の忌避) → `.claude/rules/compat_tiers.md` で「Tier 外コード書くな」を ad-hoc 防止層として明文化
- §2 A7 (Day 1 から並行性とエラー設計を組込む) → `concurrency_design.md` を Day 0 で確定
- §11.6 (新設) → 全 quality gate を 1 表で管理
- §G1 / §G2 / §G3 / §G4 / §G5 (戦略レビュー) → §G3 (decisions/) / §G4 (bench は ROADMAP §11.6 #7 に placeholder) / §G5 (fused reduce は ROADMAP §10.4) を実体化

---

## 確認 (Try it)

### scripts と test の自己検証

```sh
$ bash scripts/zone_check.sh
(informational mode: exit 0 regardless of violations)

$ bash scripts/zone_check.sh --strict
(no output)
$ echo $?
0

$ bash scripts/zone_check.sh --gate
0

$ bash test/run_all.sh
==> 1. zig build test
    OK

All test suites passed.
```

### `.claude/rules/` の自動ロード確認

新しいセッションで `src/main.zig` を read/edit すると、`zone_deps.md` と
`zig_tips.md` が自動でロードされる (paths frontmatter による)。Claude が
「`std.io.AnyWriter` を使う」「`pub var` で vtable を作る」のようなアンチ
パターンを書きにくくなる。

### Learning-doc gate (このコミット自体での発火)

このコミットは `.dev/decisions/0000-template.md` を新規追加するため、
gate ルール (`.dev/decisions/*.md` パターンに match) が発火する。
本ファイル `docs/ja/0002-audit-and-scaffolding.md` を同時に stage してあるので
gate を通過する。`.dev/decisions/` が gate 対象になっているのは
「ADR 追加 = 設計判断の commit = 学習ノート対象」という見立て。

---

## 学び (Takeaway)

### 自律開発インフラの一般知識

- **Day 0 の空ファイル / 空 directory は十分価値がある**: ADR template を
  Day 0 で用意しておくと、Phase 1 の最初の判断が ADR 0001 として
  自然に書かれる。後付けで「過去の決定を ADR 化」しようとすると粒度・
  意図が失われる
- **「将来動くゲート」は roadmap で 1 表にしないと忘れる**: Phase ごとの
  task list に分散させると、横串で「全 gate がいつ active になるか」を
  俯瞰できなくなる。Active / Planned / Prepare-by の 3 列で十分
- **ad-hoc 対応の物理阻止層**: 「Tier 外 library 用コードを書くな」を
  自然言語で書くだけでは弱い。`.claude/rules/compat_tiers.md` を path
  matched で auto-load することで、`src/lang/**` を編集している瞬間に
  Claude にルールが見える状態になる

### Claude Code 知識

- **CLAUDE.md vs `.claude/rules/X.md`**: 前者は project memory (常時ロード、
  ~200 行未満を維持)。後者は path-matched (必要時だけロード、トピックごとに
  分割可能)。ルールは後者へ、約束事は前者へ
- **`.claude/rules/` の frontmatter `paths:` 形式**: glob パターンで指定
  (例: `src/**/*.zig`)。複数指定可。マッチしたファイルを read/edit する時に
  Claude のコンテキストにロードされる
- **skill (`.claude/skills/X/SKILL.md`) との違い**: skill は description で
  semantic にトリガ (例: "git commit する時"); rules は path で機械的に
  トリガ。両方併用が普通

### Zig / shell 知識

- **`set -euo pipefail` + `grep` 無マッチ問題**: pipefail のもとで
  `grep` がマッチ無しで exit 1 → pipe 全体が exit 1 になる。
  `{ grep ... || true; }` で囲むのが定石。**「無マッチは正常」**を
  shell に明示しないと bug になる
- **bash `case` glob pattern**: `.dev/decisions/*.md` のような複数階層 glob
  は `case` 構文でそのまま使える。check_learning_doc.sh のゲート判定が
  この機構で動いている
- **PreToolUse hook の matcher**: `Bash` ですべての shell 呼び出しを intercept、
  内部で `git commit` のみ反応するよう自前で仕分け、というパターンが堅実。
  Claude Code 側で完全な matcher 構文 (例: `Bash(git commit:*)`) もあるが、
  シェルレベルで JSON 解析する方が将来の拡張に強い

### Clojure 処理系設計知識

- **Tier 制 (A/B/C/D)**: ad-hoc な互換実装の沼を阻止するための名前付け。
  Babashka が「pod として外出し」、SCI が「pre-selected Java classes 限定」を
  したのと同じ問題への異なる解。本プロジェクトは「Tier + pod」両方
- **pod = Wasm Component**: Babashka の subprocess pod を Wasm Component で
  再発明する着想。エコシステム互換問題の escape hatch であり、同時に
  ClojureWasm v2 の差別化軸そのものになる
- **deep dive doc を Day 0 で書く意義**: concurrency_design / wasm_strategy
  のような **概念設計** は、実装が始まる前に独立ファイルで凍結しておかないと
  「Phase 15 の中で都度議論」になる。1 度議論して文書化すれば次の Claude
  セッションがその上に積める
