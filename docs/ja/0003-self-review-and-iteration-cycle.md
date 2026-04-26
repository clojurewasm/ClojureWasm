---
commits:
  - 83a4f1b
date: 2026-04-27
scope:
  - .dev/handover.md (deleted)
  - .dev/known_issues.md (deleted)
  - .dev/compat_tiers.yaml (deleted)
  - .dev/concurrency_design.md (deleted)
  - .dev/wasm_strategy.md (deleted)
  - .claude/rules/compat_tiers.md (deleted)
  - docs/README.md (deleted)
  - .dev/ROADMAP.md (§5, §11.6 #1, §12.2, §15.1, §15.2 新設, §17)
  - .dev/README.md (大幅縮小 + create-on-demand 表記)
  - .dev/decisions/README.md (gate 表現を新ルールに合わせる)
  - .claude/skills/code-learning-doc/SKILL.md (新ルール反映 + workflow 書き換え)
  - scripts/check_learning_doc.sh (rule 1 + rule 2 の新ロジック)
  - CLAUDE.md (新ルール反映)
  - docs/ja/0001-project-bootstrap.md (commit: 116b874 へ patch)
  - docs/ja/0002-audit-and-scaffolding.md (commit: ac2e2b9 へ patch)
related:
  - ROADMAP §11.6 #1 (Learning-doc gate, new behavior)
  - ROADMAP §12.2 (Commit pairing: source commit → doc commit)
  - ROADMAP §15.2 (Files created on demand)
  - ROADMAP §17 (revision history)
---

# 0003 — セルフレビュー、簡素化、コミットイテレーションの形式化

ブートストラップ + 監査の 2 イテレーションを終えた時点でセルフレビュー。
**「ファイルが多いと参照されない・メンテされない・陳腐化する」** という
普遍則に照らして 7 ファイルを削除。同時に「source commit → doc commit を
**別コミット** にする」運用に切り替え、`commit:` SHA を後埋めしなくて済む
形に整える。最後に **1 イテレーションで何が走り何が記録されるか** の
全体像を 1 つの ASCII 図にまとめる (本ファイルの主目的のひとつ)。

---

## 背景 (Background)

### LLM 主導の自律開発でファイルが腐る経路

経験則: ある種類のファイルは **作っただけでは使われない**:

1. **空 stub** (`.dev/handover.md` を空で committing)
   → 「あるけど中身ない」が常態化、新規セッションで読まれない
2. **aspirational table** (`.dev/compat_tiers.yaml` を実装ゼロで列挙)
   → 実装と乖離する、信頼ゼロで放置
3. **早期 deep-dive** (`.dev/concurrency_design.md` を Phase 15 まで凍結)
   → Phase 15 が来たころには Zig stdlib が変わっていて該当しない
4. **盲点的 placeholder** (`docs/README.md` で ja/ を指すだけ)
   → main `README.md` と重複、両方更新を強いる

これらは bootstrap commit (`116b874`) では「将来のため」と入れたが、
監査 commit (`ac2e2b9`) で **倍** になった。
2 つ作って 1 つでも腐ると signal/noise が悪化する。

### コミットハッシュの後埋め問題

学習ドキュメントの frontmatter `commit:` フィールドは、書いている当人が
当該 source 変更と同じコミットに doc を含めると **その時点では未確定** で、
TBD と書いて後で patch するしかなかった。これは:

- 後 patch の commit が必要 (もう 1 個 chore commit)
- 患った patch を忘れると TBD が永久残り
- skill template に「TBD then patch」というアンチパターンを正解として書く羽目になる

→ **doc を source の次の commit にすれば** SHA は確定済み。frontmatter に
そのまま書ける。後 patch なし。

---

## やったこと (What)

### 削除 (7 ファイル)

| ファイル                          | 削除理由                                                  | 復活条件                            |
|-----------------------------------|-----------------------------------------------------------|-------------------------------------|
| `.dev/handover.md`                | 空 stub。memo は常態化すると腐る                          | 実セッション間引き継ぎ要求が出た時 |
| `.dev/known_issues.md`            | 空 stub。issue 0 件で構造だけある                        | 初の P0-P3 が発生した時             |
| `.dev/compat_tiers.yaml`          | aspirational。Phase 10 の実装ゼロで列挙だけ              | 初の `src/lang/clj/` が landing     |
| `.dev/concurrency_design.md`      | Phase 15 まで凍結 + ROADMAP §7 と内容重複                | (基本不要、Phase 15 で必要なら ADR) |
| `.dev/wasm_strategy.md`           | Phase 14/19 まで凍結 + ROADMAP §8 と内容重複             | (同上)                              |
| `.claude/rules/compat_tiers.md`   | `src/lang/**` 不在で auto-load 機会ゼロ                  | `compat_tiers.yaml` 復活と同時      |
| `docs/README.md`                  | `docs/ja/` への単行 placeholder。main README で十分      | 英語 `docs/` 系ファイル増加時       |

これらは **削除して終わり** ではなく、ROADMAP §15.2 「Files created on
demand」に **テンプレートと復活条件** を明記してある。「形式が失われた」
にはならない。

### 削除しなかった (= 即時価値あり)

| ファイル                                  | 残す理由                                              |
|------------------------------------------|------------------------------------------------------|
| `.claude/rules/zone_deps.md`             | Phase 1 で src/ を触り始めた瞬間に auto-load される |
| `.claude/rules/zig_tips.md`              | 同上、Zig 0.16 idiom リマインダ                     |
| `.claude/skills/code-learning-doc/SKILL.md` | 毎 commit で参照、生きている                       |
| `scripts/check_learning_doc.sh`           | 毎 git commit で発火するゲート                      |
| `scripts/zone_check.sh`                   | 空 src/ でも exit 0、すぐ使える                     |
| `test/run_all.sh`                         | 単一テスト entry point、Phase ごとに suite 追加     |
| `.dev/decisions/{README,0000-template}.md` | ADR は判断発生時に必ず必要、template は 1 行で機能 |

### コミット運用変更: source commit → doc commit を別 commit に

**旧運用** (commit 1, 2 で適用):
```
1 commit: source files + docs/ja/NNNN-*.md (commit: TBD)
↓
事後 patch commit でTBD → 実 SHA に書き換え
```

**新運用** (commit 3 以降):
```
commit N      source files only         (例: feat(eval): add tree_walk)
commit N+1    docs/ja/NNNN-*.md only    (commit: <N の SHA> をそのまま埋める)
```

ゲートは新ルール 2 本で運用:
- **Rule 1**: doc commit に source を混ぜるな (混ぜたら SHA 対応が崩れる)
- **Rule 2**: 直前 commit が unpaired source なら、次 commit は必ずその doc

### Source-bearing 判定の精度向上

旧 `is_source_path` は `.dev/decisions/*.md` で `README.md` や
`0000-template.md` まで誤って source として拾っていた。新パターンは:

```bash
case "$1" in
  src/*.zig|build.zig|build.zig.zon)        return 0 ;;
  .dev/decisions/0000-*.md)                  return 1 ;;   # template
  .dev/decisions/[0-9][0-9][0-9][0-9]-*.md) return 0 ;;   # real ADR
  *)                                         return 1 ;;
esac
```

メタファイルを除外し、本物 ADR (`NNNN-<slug>.md`、N≥1) のみを source-bearing と扱う。

### 既存ドキュメントの SHA 後埋め

- `docs/ja/0001-project-bootstrap.md`: `commit: TBD` → `commit: 116b874`
- `docs/ja/0002-audit-and-scaffolding.md`: `commit: TBD` → `commit: ac2e2b9`

---

## コード (Snapshot)

### 新ゲート script `scripts/check_learning_doc.sh` (中核ロジック)

```bash
# Rule 1: doc commits must not contain source-bearing files
if [ $this_has_doc -eq 1 ] && [ $this_has_source -eq 1 ]; then
  cat >&2 <<'EOF'
✗ A learning-doc commit must NOT also contain source-bearing files.
   Split into two commits:
     git commit -m "feat(...): ..."   # source only
     git commit -m "docs(ja): ..."    # the learning doc only
EOF
  exit 1
fi

# Rule 2: previous source commit must be paired in this commit
if [ $prev_is_unpaired_source -eq 1 ] && [ $this_has_doc -eq 0 ]; then
  prev_sha="$(git log -1 --format=%h HEAD)"
  cat >&2 <<EOF
✗ The previous commit (${prev_sha}) added source-bearing files but no
  learning doc accompanied it. The next commit MUST add docs/ja/NNNN-<slug>.md
  with \`commit: ${prev_sha}\` in its front matter.
EOF
  exit 1
fi
```

### ROADMAP §15.2 (新設、create-on-demand template)

```markdown
### 15.2 Files created on demand (do not pre-create as empty stubs)

Empty files rot. These are created the moment they have real content,
using the templates below.

#### `.dev/handover.md` — when a session ends mid-task ...
#### `.dev/known_issues.md` — when the first long-lived issue surfaces
#### `.dev/compat_tiers.yaml` — when the first src/lang/clj/<ns>.clj lands
#### `.dev/status/vars.yaml` — when Phase 2.19 generator script lands
```

---

## なぜ (Why)

### 簡素化の判断基準

「シンプル化しつつ自律開発のガードレールとして十分機能」(ユーザ指示) を
満たすため、各ファイルを **rot リスク** × **即時価値** の 2 軸で評価:

```
                       即時価値 高
                            |
        keep              | keep
        (zone_deps,       | (CLAUDE, ROADMAP,
         zig_tips,        |  scripts, skill)
         decisions/       |
         template)        |
                          |
     ─────────────────────┼─────────────────────
                          |
        cut               | (ありえない、
        (handover,        |  即時価値高ければ
         known_issues,    |   rot しない)
         compat_tiers,    |
         deep-dives,      |
         compat_rule,     |
         docs/README)     |
                          |
                       即時価値 低
```

「即時価値低 + rot リスク高」の 7 個を切る、というのが定量的判断。
ROADMAP §15.2 でテンプレート保存しているので **形式知は失わない**。

### コミット分離の判断

doc 同梱 vs doc 別コミットの trade-off:

| 観点                     | 同コミット (旧)         | 別コミット (新)           |
|-------------------------|-------------------------|---------------------------|
| `commit:` SHA           | TBD → patch (後埋め必要) | 実 SHA を直接書ける        |
| commit 数               | 半分                     | 倍                         |
| commit メッセージ        | source + doc 混在        | source / doc それぞれ専用 |
| `git log --oneline` 可読性 | 中                       | 高 (source と doc が交互)  |
| revert 容易性            | doc も同時に消える       | source だけ revert 可能   |
| review 容易性            | 1 PR で source + doc     | 2 commits で順に追える    |

新運用の commit 数倍化はコストだが、**SHA 管理 / git log 可読性 / revert
柔軟性** がそれを上回る。Patch 後付けは 1 度やるだけで「忘れたら永久 TBD」
リスクがあり、構造的に避けたい。

### ゲート Rule 1 / Rule 2 の役割分担

- Rule 1 (doc に source 混ぜるな): SHA 対応が崩れる物理的阻止
- Rule 2 (unpaired source の次は doc): doc 書き忘れの物理的阻止

両方揃って初めて「source commit → doc commit のペアが成立し続ける」が
保証される。片方だけでは穴がある。

---

## 1 イテレーション = 何が実行され / 記録され / 参照されるか

ユーザ指示「1 イテレートされる度に何が実行され何が記録されるか、その際何が
参照されるか (rules / SKILL も含め) ja ドキュメントに含める」への回答。

```
SESSION START
├── 自動ロード: CLAUDE.md (project memory、毎セッション)
└── 継承: 直前チャット履歴 (or 新規)

PER ITERATION (= 1 つのタスク = 2 commit のペア)
│
├── (1) ORIENT
│   ├── 参照: .dev/ROADMAP.md §9 (current phase task)
│   ├── 参照: git log (recent commits)
│   ├── 参照: .dev/decisions/NNNN-*.md (該当判断あれば)
│   ├── 参照: .dev/handover.md (存在すれば。なければスキップ)
│   └── 出力: chosen task statement (chat / TaskCreate)
│
├── (2) PLAN
│   └── 出力: 短い plan (chat)
│
├── (3) EXECUTE (TDD: red → green → refactor)
│   ├── 編集: src/**/*.zig
│   │   └── ★自動ロード (path-matched on edit/read):
│   │       ├── .claude/rules/zone_deps.md   (paths: src/**/*.zig, build.zig)
│   │       └── .claude/rules/zig_tips.md    (paths: src/**/*.zig, build.zig)
│   │       (将来 .claude/rules/compat_tiers.md が src/lang/** で auto-load)
│   ├── 実行: bash test/run_all.sh (= zig build test 現状)
│   ├── (将来 Phase 2.20+) bash scripts/zone_check.sh --gate
│   └── 出力: working tree のコード変更 + green tests
│
├── (4) SOURCE COMMIT
│   ├── git add src/... build.zig ...                     (source only)
│   ├── git commit -m "feat(scope): one-line summary"
│   ├── ★HOOK 発火: PreToolUse on Bash
│   │   └── scripts/check_learning_doc.sh
│   │       ├── stdin から tool_input.command を JSON 解析 (python3)
│   │       ├── git commit のみ filter
│   │       ├── HEAD 検査 → prev_is_unpaired_source 判定
│   │       ├── 今回 stage 検査 → this_has_source / this_has_doc
│   │       ├── Rule 1: doc + source 混在 → block
│   │       ├── Rule 2: prev unpaired + this not doc → block
│   │       └── pass → exit 0
│   ├── 結果: HEAD = 新 source commit (unpaired source)
│   └── ★スキル ON-DEMAND ロード:
│       └── .claude/skills/code-learning-doc/SKILL.md
│           (description が "git commit したばかりで source staged" にマッチ)
│
├── (5) WRITE LEARNING DOC
│   ├── 参照: 直前 source commit の SHA (`git log -1 --format=%h`)
│   ├── 参照: SKILL.md の template (背景 / やったこと / コード / なぜ / 確認 / 学び)
│   ├── 参照: 該当 ROADMAP §, ADR, .claude/rules/* (背景知識として)
│   ├── 出力: docs/ja/NNNN-<slug>.md (commit: <prev SHA> を frontmatter に)
│   └── (任意) `.dev/decisions/NNNN-*.md` を追加 (load-bearing 判断あれば)
│
├── (6) DOC COMMIT
│   ├── git add docs/ja/NNNN-*.md
│   ├── git commit -m "docs(ja): NNNN — title (#<prev SHA>)"
│   ├── ★HOOK 発火: 同じく PreToolUse on Bash
│   │   ├── this_has_doc = 1, this_has_source = 0
│   │   ├── Rule 1: source 混在なし → pass
│   │   ├── Rule 2: prev は unpaired source、this は doc → pass
│   │   └── exit 0
│   └── 結果: HEAD = doc commit (paired with previous source commit)
│
├── (7) (任意) UPDATE LIVE FILES
│   ├── 必要なら .dev/handover.md (mid-task 引継ぎ要なら作成 / 更新)
│   ├── 必要なら .dev/known_issues.md (P0-P3 発生なら追加)
│   └── これらは 3 通り目の commit になる (chore commit、source じゃない)
│
└── (8) PUSH (ユーザ承認後のみ)
    └── git push origin cw-from-scratch
```

### 各リソースの「いつロードされるか」一覧

| リソース                                  | ロード trigger                                          | 寿命                  |
|------------------------------------------|---------------------------------------------------------|----------------------|
| `CLAUDE.md`                               | セッション開始時 (毎回)                                | セッション全期間     |
| `.claude/rules/zone_deps.md`              | `src/**/*.zig` または `build.zig` を Read/Edit する瞬間 | その後セッション中   |
| `.claude/rules/zig_tips.md`               | 同上                                                   | 同上                 |
| `.claude/skills/code-learning-doc/SKILL.md`| description match で discovery → 必要時 ロード         | ロード後セッション中 |
| `.dev/ROADMAP.md`                         | Claude が必要に応じて Read (orient / 設計判断時)       | 都度                 |
| `.dev/decisions/NNNN-*.md`                | 過去判断を recall する時に Read                        | 都度                 |
| `scripts/check_learning_doc.sh`           | 毎 Bash 呼び出しで PreToolUse hook が起動              | スクリプト実行のみ   |
| `scripts/zone_check.sh`                   | Phase 2.20+ で test/run_all.sh または手動              | スクリプト実行のみ   |
| `test/run_all.sh`                         | 毎テスト走行で手動 or hook                             | スクリプト実行のみ   |

### 各記録の「どこに残るか」一覧

| 記録対象                       | 永続化先                                                |
|--------------------------------|---------------------------------------------------------|
| 何のコードが書かれたか         | git commit (source side)                                |
| なぜそう書いたか / 背景知識    | docs/ja/NNNN-<slug>.md (doc side)                       |
| 構造的 / load-bearing 判断     | .dev/decisions/NNNN-<slug>.md (ADR)                     |
| ミッション / 原則 / 計画変更    | .dev/ROADMAP.md (§17 改訂履歴に追記)                    |
| 短期セッション間引き継ぎ        | .dev/handover.md (必要な時のみ作成)                     |
| 長期 debt                       | .dev/known_issues.md (P0-P3、必要な時のみ作成)         |
| Tier 表の現実状況               | .dev/compat_tiers.yaml (Phase 10+)                      |
| var 実装進捗                    | .dev/status/vars.yaml (Phase 2.19+)                     |

---

## 確認 (Try it)

### ファイル数の変化

```sh
# Before (commit 2 = ac2e2b9)
$ ls .dev/ .claude/rules/ docs/ | wc -l
14

# After (commit 3 = 83a4f1b、本コミット 4 で +1)
$ ls .dev/ .claude/rules/ docs/ | wc -l
8
```

(数字は概算。`ls` の挙動でコミット時とずれる場合あり)

### ゲートの新ロジック自己検証

```sh
# Setup: 一時的に src を変更して staging
$ echo "// touch" >> src/main.zig && git add src/main.zig

# Source commit を Claude 経由で実行 → pass (HEAD = doc 付きペア commit)
$ echo '{"tool_input":{"command":"git commit -m wip"}}' \
    | bash scripts/check_learning_doc.sh
$ echo "exit=$?"   # → 0

# git commit 実行 (本物)
$ git commit -m "wip: touch"

# 連続して source を 2 回目 → BLOCK (prev_is_unpaired)
$ echo "// touch2" >> src/main.zig && git add src/main.zig
$ echo '{"tool_input":{"command":"git commit -m wip2"}}' \
    | bash scripts/check_learning_doc.sh
✗ The previous commit (...) added source-bearing files but no learning
  doc accompanied it. The next commit MUST add docs/ja/NNNN-<slug>.md ...
$ echo "exit=$?"   # → 1

# Cleanup
$ git reset HEAD~1 --hard
```

---

## 学び (Takeaway)

### 自律開発インフラの設計知識

- **ファイル数 = 継続コスト**: 「念のため空 stub」「将来のための placeholder」は
  必ず腐る。template + 復活条件を 1 箇所 (ROADMAP §15.2) に集約することで
  「形式は失わずファイルは増やさない」を両立できる
- **Rule 1 + Rule 2 の対称性**: ゲートに 1 つのルールしかないと必ず穴が空く。
  「source に doc 混ぜるな」と「unpaired source の次は doc」の双対で
  source-doc ペアが連続的に成立する
- **commit 単位の選び方**: 「1 task = 1 commit」だけでは粒度が決まらない。
  「source と doc を別 commit」が SHA 連動 / log 可読性 / revert 柔軟性を
  改善する。コミット数倍化のコストを上回る
- **Path-matched rule の有効範囲**: `.claude/rules/X.md` は frontmatter の
  `paths:` に match した瞬間にロードされる。`src/lang/**` のように
  まだ存在しないパスを指定する rule は **add する瞬間が遅い** ので、
  Phase 10 で `.claude/rules/compat_tiers.md` を `compat_tiers.yaml` と
  セットで作成する

### Zig / shell 知識 (今回新規)

- **`git stash --include-untracked --keep-index`**: 一見便利だが、自己テスト
  ループ内で打つと **直近の全編集を吹き飛ばす** ので注意。`git stash pop`
  で復旧可能だが、conflict が出ると面倒。本イテレーションで踏んで戻した
- **`grep -E '^.*\.dev/decisions/[0-9][0-9][0-9][0-9]-.+\.md$'`**: bash
  `case` の glob とは別構文。`case` では `[0-9][0-9][0-9][0-9]-*.md` のような
  POSIX glob を使う。ERE と glob の混同は典型的バグ源
- **shell `case` の優先順** : 上から match する最初の pattern が選ばれる。
  `0000-*.md` を `[0-9][0-9][0-9][0-9]-*.md` の **前** に置くことで template
  除外を実現

### Claude Code 自律開発知識

- **Linter modification 警告**: 直前に Read していないファイルへの Edit は
  「modified since read」で弾かれる。Write は強制上書きで通る (リスクは
  自分で持つ)。複雑な multi-file edit では Read → Edit → Read → Edit を
  繰り返すか、Bash で grep して内容把握 → Write で全体上書きが安全
- **PreToolUse hook の Subject**: 全 Bash 呼び出しを matcher にしておき、
  内部で `git commit` のみ反応させる方式が将来拡張に強い (matcher を
  「Bash(git commit:*)」に絞ると、`FOO=bar git commit ...` のような
  prefix env を逃す)
- **ROADMAP § と CLAUDE.md / SKILL.md の重複**: 同じルールを 3 ファイルに
  書くと同期コストが発生する。canonical は ROADMAP、他は **要約 + 参照** の
  形にしておくと drift が少ない (本イテレーションで Rule 1/2 の表現が
  3 ファイルでズレないよう precision fix した)
