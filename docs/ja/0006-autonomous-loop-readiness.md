---
commits:
  - 6b93222
date: 2026-04-27
scope:
  - .claude/settings.json (defaultMode + additionalDirectories + permissions 拡張 + SessionStart hook)
  - .claude/skills/continue/SKILL.md (Phase-boundary review chain 追加)
  - CLAUDE.md (Skills 節 — auto chain への参照)
related:
  - ROADMAP §11.7 (Periodic scaffolding audit)
  - skill audit-scaffolding (Phase boundary で auto-invoke)
  - 公式: Claude Code permission modes / hooks / autonomous mode (2026-04 時点)
---

# 0006 — 自律実行 readiness — Phase 1.1 着手前の最終整備

「`/continue` だけで Phase 1 が完走するか」を担保するための最終
イテレーション。**自律実行ノウハウの 2026-04 web 調査 + audit-scaffolding
セルフレビュー + Phase 1.1 のフロー仮想トレース** を踏まえ、
permissions / hook / skill chain を整備した。

---

## 背景 (Background)

### 旧 FromScratch の介入前提と本プロジェクトの方針

旧 FromScratch (`~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref`)
は人間の介入を **頻繁に** 想定した作りだった。permission prompts、
明示 invocation、各 commit の確認 — どれも自然な「停止点」として
機能していた。

本プロジェクトでは **「極力止めず、意味のある checkpoint でだけ止める」**
を目指す。意味のある checkpoint は:

1. 初回 "go" (TDD 開始の許可)
2. Phase 境界 (review chain 結果報告 + 次 Phase 開始の許可)
3. `git push` (本家リモートへの公開、CLAUDE.md 規約)
4. 真の blocker (テスト失敗の root cause が architectural / GC corner case など)

それ以外の機械的な停止 (mkdir 確認、git add 確認、Edit 承認) は
**全部裏で auto-approve** したい。

### 2026-04 の Claude Code 自律実行ノウハウ (調査結果)

Web 調査で判明した主要パターン:

| 手段                                   | 目的                                         | 採否                                    |
|----------------------------------------|----------------------------------------------|------------------------------------------|
| `--dangerously-skip-permissions`       | "Safe YOLO": 全 permission prompt をスキップ | **不採用** (containerized 用、bare metal 危険) |
| **Auto Mode** (model-based classifier) | 中間: 危険行動だけ classifier が拒否       | watch (将来採用候補)                    |
| **Headless `-p`** (CLI flag)           | 完全非対話、`claude -p "..."` で 1 shot     | 不採用 (ここは対話セッション)           |
| `/loop` / `/schedule`                  | 周期実行 / cron                              | 不採用 (本プロジェクトは対話駆動)       |
| **`defaultMode: acceptEdits`**         | Edit/Write/MultiEdit を auto-accept          | **採用**                                 |
| **`permissions.allow` 厳密リスト**      | 安全な Bash を pre-approve                  | **採用** (拡張)                         |
| **`permissions.additionalDirectories`** | 参照 clone を Read 許可                     | **採用**                                 |
| **`hooks.SessionStart`**                | セッション起動時に context 注入            | **採用** (handover を auto-print)        |
| **`hooks.PostToolUse` for fmt**        | Edit 後に zig fmt 自動                      | 見送り (Phase 1 のコード量が小さい)     |
| **`hooks.PermissionRequest`**          | model-driven auto-approve                   | 見送り (機能が不安定との報告)           |

### audit-scaffolding によるセルフレビュー結果 (本イテレーション開始時)

CHECKS.md A-E カテゴリを実行:

| Check | 結果 |
|-------|------|
| A1 ROADMAP §5 vs filesystem      | 47 path 言及。すべて整合 |
| A4 ja doc commits SHA 実在        | 5/5 ✓ (0001-116b874, 0002-ac2e2b9, 0003-83a4f1b, 0004-5750e91, 0005-d35a612) |
| B1 ファイルサイズ                  | すべて soft limit 内 (CLAUDE 94/100, SKILL 57-93/150 等) |
| B2 重複事実                       | "source-bearing" / "Rule 1/2" / "commit pairing" は **canonical 1 + pointers N の構造** で OK (drift 兆候なし) |
| C2 reference clones 実在          | 5/5 ✓ |
| (other)                           | 0 findings |

→ **block / soon どちらも 0**。スキャフォールド側に直すべき腐敗なし。
本イテレーションの作業は **autonomous-flow readiness の追加** のみ。

---

## やったこと (What)

### 6b93222 — Permissions 拡張 + SessionStart hook + Phase-boundary chain

#### (1) `defaultMode: acceptEdits`

Edit / Write / MultiEdit ツールがセッション中ずっと auto-accept。
TDD の red / green / refactor で発生する Zig ファイル編集が
permission prompt を出さない。

#### (2) `permissions.additionalDirectories`

reference clones (v1 / v1_ref / OSS clones 8 件) を Read 許可
リストに追加。`Read` ツールが prompt なしで参照できる。これにより
「v1 の value.zig はどう書いてたか?」を Claude が自発的に
読みに行ける。

#### (3) `permissions.allow` 大幅拡張

Phase 1 で必要となる Bash を pre-approve:

```
git: status / log / diff / show / branch / switch / stash / add / commit /
     rev-parse / rev-list / ls-files / remote / fetch / config --get /
     restore / diff-tree
file: mkdir / touch / cp / mv / chmod / printf / echo
text: grep / awk / sed / find / head / tail / sort / uniq / diff / wc / cat / ls
lang: bash / python3 / zig / nix develop / nix flake / direnv
```

**`git push` は意図的に未許可**。CLAUDE.md「explicit user approval」
規約と整合し、push 時だけ permission prompt が出る (= 意味のある checkpoint)。

#### (4) `permissions.deny` 強化

`git push --force` / `--force-with-lease`、`git reset --hard`、
`git rebase`、`rm -rf` の危険パス (`/`, `~/`, `$HOME`, `.git`) を
明示的に deny。

#### (5) `hooks.SessionStart`

新規 lifecycle hook。セッション起動時に:

```bash
cat .dev/handover.md
git log -3 --decorate --oneline
```

を実行、stdout が Claude の `additionalContext` に注入される。
新セッションで Claude が即座に「現状 + 直近 3 commit」を把握できる。
ユーザは「続けて」と言うだけで OK (handover を見直さなくていい)。

#### (6) skill `continue` に Phase-boundary review chain 追加

Phase が閉じた瞬間 (= doc commit の `commits:` リストに §9.<N>
最後の `[ ]` を `[x]` にした SHA が含まれる) に、自動で:

1. **`audit-scaffolding`** invoke — staleness / bloat / drift 検出
2. **built-in `simplify`** invoke — Phase の `git diff <start>..HEAD -- src/` に対して
3. **built-in `security-review`** invoke — unpushed commits に対して
4. **報告** — block findings あれば停止、ユーザに修正方針確認
5. **次 Phase opening** — block 0 なら §9 phase tracker flip + §9.<N+1>
   inline 展開 + handover.md 更新

→ **明示 `/simplify` `/review` `/security-review` invocation は不要**。
ユーザの希望「明示的に呼ばないと実行されない系は避けたい」に対応。

#### (7) skill `continue` description 強化 + 「stop / keep going」rule 明示

description に "drives the TDD loop autonomously through to the doc
commit" + 日本語 phrase ("続けて", "次", "go") を追加 → auto-trigger
精度向上。

「When to stop, when to keep going」節で、停止すべき 6 ケースと
継続すべき 3 ケースを箇条書き。Claude が「念のため確認」で過剰停止
する防止策。

---

## コード (Snapshot)

### `.claude/settings.json` (改善後の主要部)

```json
{
  "defaultMode": "acceptEdits",
  "permissions": {
    "additionalDirectories": [
      "~/Documents/MyProducts/ClojureWasm",
      "~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref",
      "~/Documents/OSS/clojure", "~/Documents/OSS/babashka",
      "~/Documents/OSS/zig",     "~/Documents/OSS/spec.alpha",
      "~/Documents/OSS/wasmtime","~/Documents/OSS/malli",
      "~/Documents/OSS/mattpocock_skills"
    ],
    "allow": [
      "Bash(zig:*)", "Bash(bash:*)", "Bash(python3:*)",
      "Bash(git status:*)", "Bash(git add:*)", "Bash(git commit:*)",
      ...
    ],
    "deny": [
      "Bash(git push --force:*)", "Bash(git reset --hard:*)",
      "Bash(git rebase:*)", "Bash(rm -rf /:*)", ...
    ]
  },
  "hooks": {
    "SessionStart": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "test -f $CLAUDE_PROJECT_DIR/.dev/handover.md && cat $CLAUDE_PROJECT_DIR/.dev/handover.md && git -C $CLAUDE_PROJECT_DIR log -3 --decorate --oneline || true"
      }]
    }],
    "PreToolUse": [{...check_learning_doc.sh...}]
  }
}
```

### skill `continue` の Phase-boundary chain (新規)

```markdown
## Phase boundary review chain (auto-runs when a Phase closes)

A Phase closes when the doc commit's `commits:` list includes the SHA
that flipped the last `[ ]` to `[x]` in §9.<N>. **Do not open §9.<N+1>
immediately.** Run this chain (auto, no user prompt needed):

1. **`audit-scaffolding` skill** — staleness / bloat / drift across
   CLAUDE.md, .dev/, .claude/, docs/, scripts/. Block-severity findings
   pause the chain.
2. **Built-in `simplify` skill** on the Phase's combined diff
   (`git diff <phase-start>..HEAD -- src/`). Apply suggestions that
   don't change behaviour; queue larger ones for the next Phase.
3. **Built-in `security-review` skill** on unpushed commits.
4. **Report findings** to the user with severity counts. ...
5. **Open §9.<N+1>**: flip the §9 phase tracker; expand §9.<N+1> ...
```

### Phase 1.1 自律フロー (仮想トレース)

```
[SESSION START]
  hook → cat handover.md → "Phase 1, 1.1 next, last commit ..."
  hook → git log -3      → "..."
  ↓ Claude has context already

[USER] 続けて
  ↓ skill `continue` description matches → loaded
  Claude: read ROADMAP §9.3 → bash test/run_all.sh (✓ allowed)
        → summarise: "Phase 1, last 6b93222, tests OK, 1.1 next, exit criterion ..."
        → wait for go

[USER] go
  ↓ TDD loop starts
  ┌─ Plan: red test for Value.initInteger(42)        [no perm]
  │  Edit src/runtime/value.zig (test block)         [auto-accept]
  │  bash test/run_all.sh                            [allowed]
  │  RED ✓
  │  Edit src/runtime/value.zig (impl)               [auto-accept]
  │  bash test/run_all.sh                            [allowed]
  │  GREEN ✓
  │  git add src/runtime/value.zig                   [allowed]
  │  git commit -m "feat(runtime): NaN boxing Value" [allowed; gate: no doc needed]
  │  ↓ source commit landed
  │  Edit ROADMAP.md (1.1 → [x] <SHA>)               [auto-accept]
  │  Edit handover.md (next: 1.2)                    [auto-accept]
  └─ ... loop to 1.2 ...

[After 1.12 [x]]
  Doc commit: copy TEMPLATE.md → docs/ja/0007-phase-1-foundations.md
              fill in commits: [<1.1 SHA>, ..., <1.12 SHA>]
              git add + git commit
  ↓ gate: this_has_doc=1, expected = all 1.1-1.12 SHAs, covered = same → pass

[Phase 1 close detected]
  ↓ AUTO Phase-boundary review chain
  Invoke skill audit-scaffolding (Skill tool, no perm)
  Invoke skill simplify (Skill tool, no perm)  → reports on src/ diff
  Invoke skill security-review (Skill tool, no perm)
  Report: "block 0, soon X, watch Y. Ready for Phase 2?"
  ↓ wait for user direction

[USER] go for Phase 2
  ↓ Open §9.4 inline, mark Phase 2 IN-PROGRESS, update handover, start 2.1
```

**停止点は意図したもののみ**: 初回 go / Phase boundary 報告 / push 承認。

---

## なぜ (Why)

### `--dangerously-skip-permissions` 不採用

調査結果: Anthropic 自身が "Run this in a container, not your actual
machine" と明言。bare metal で全 permission をスキップすると、Claude
が誤って `~/` 全体を消す等のリスクが残る。

代替: **granular permissions allow + acceptEdits** で 95% の prompt を
排除。残り 5% (git push, 危険操作) は意味的に必要な checkpoint。

### Auto Mode (model-based classifier) 見送り

新機能で「中間モード」と説明されているが、2026-04 時点での実評価
レポートが少ない。本プロジェクトの規模なら granular allowlist で
十分カバーでき、複雑性を入れる必要がない。将来 src/ が大きくなった
ときに再評価。

### Phase-boundary review chain を skill に内蔵

候補:
- (A) ユーザが `/audit` `/simplify` `/security-review` を毎回 invoke → 忘却必至
- (B) PostToolUse hook で `git commit` 後に invoke → 過剰 (毎 commit で fire)
- (C) **skill `continue` 内で「Phase 閉じた」を検出して auto-invoke** → 採用

(C) は LLM 介入で「Phase 閉じた」判定が必要だが、`commits:` リストと
§9.<N> の `[x]` 状況を見れば機械的に判定可能。skill 内で擬似コード
書ける。

### refactor フェーズの粒度判定

ユーザの問い: "/simplify /review /security-review を呼ぶ、過剰か？"

| 粒度          | 判断                                              |
|---------------|---------------------------------------------------|
| 毎 source commit | **過剰** (TDD の green ごとに review は意味薄い) |
| 毎 doc commit | やや過剰 (unit of work が小さいと頻繁すぎる)      |
| **Phase 境界** | **適切** (Phase は数日〜数週、十分な変更量がある) |
| Pre-push      | あり (push 前に最終 sanity)                       |
| Pre-tag (release) | 必須 (公開前)                                  |

→ skill `continue` で Phase 境界 auto。Pre-push は手動 (push 自体が
ユーザ承認なので、その流れで invoke できる)。Pre-tag は将来 Phase 14
で考える。

### SessionStart hook で handover.md 自動 print

「ユーザが `/continue` を打たないと skill が起動しない」を回避するため。
SessionStart hook は **必ず** 起動するので、ユーザが何も言わなくても
Claude は handover を context に持つ。最初の発話が「続けて」じゃなく
ても (例: 「進めて」「やって」「えっと、Phase 1 の続きから」) 文脈
ありで対応できる。

---

## 確認 (Try it)

### permission lists の網羅性チェック

```sh
# Phase 1 で発火するであろう全 Bash を列挙し、allow/deny に該当するか
$ for cmd in 'zig build' 'zig build test' 'zig fmt' 'bash test/run_all.sh' \
             'git add src/x.zig' 'git commit -m foo' 'git status' \
             'git log --oneline' 'git rev-parse HEAD' \
             'mkdir -p src/runtime/gc' 'cp TEMPLATE.md docs/ja/0007.md' \
             'python3 -c ...'; do
    echo "$cmd: should be allowed"
done
# All match Bash(...:*) entries in allow.

# Push intentionally not allowed:
$ echo 'git push origin cw-from-scratch'
# Will prompt → user approves → fine.
```

### SessionStart hook の動作確認 (次セッション)

新しい Claude Code セッションを開始すると、最初に以下が context に
注入される (期待):

```
=== .dev/handover.md ===
# Session handover
- Phase: Phase 1 IN-PROGRESS (1.0 done; 1.1 next)
...

=== git log -3 ===
6b93222 chore(claude): expand permissions, ...
2cf0c3e docs(ja): 0005 — skill refactor + scaffolding audit
d35a612 refactor(scaffolding): convert to skills, ...
```

→ ユーザが「続けて」と言う前に Claude は state を把握済み。

### Phase-boundary chain の dry-run

実際は Phase 1 完了時に走るが、いま確認したいなら手動 invoke:

```
ユーザ: /audit-scaffolding
→ skill が CHECKS.md の手順で findings を report

ユーザ: /simplify
→ built-in skill が直近変更を review

ユーザ: /security-review
→ built-in skill が現ブランチの security 観点 review
```

3 つとも個別動作可能 (今後 chain 統合)。

---

## 学び (Takeaway)

### 自律実行 4 階層モデル

Claude Code の autonomy は 4 階層に分けられる:

| 階層 | 名前                              | 採用判断 (本プロジェクト)        |
|------|-----------------------------------|----------------------------------|
| 0    | `default` (毎ツール prompt)       | テスト時のみ                    |
| 1    | `acceptEdits` (Edit auto-accept) | **採用** (Bash は allow/ask 維持) |
| 2    | Auto Mode (classifier auto-approve) | 将来検討                       |
| 3    | `bypassPermissions` (全 skip)    | 不採用 (containerized 限定)      |
| —    | `--dangerously-skip-permissions` | 不採用 (CI / headless 限定)      |

**1 と 2 の組み合わせ + granular allowlist** が本プロジェクトの
position。Phase 1 で実用性検証する。

### "明示 invocation 不要" を実現する 3 機構

1. **Skill description で auto-trigger**: 「続けて」phrase で skill
   `continue` が起動 → ユーザは自然な発話で OK
2. **SessionStart hook**: セッション起動時に context 自動注入 →
   Claude は問われる前に state を把握
3. **Skill 内で chain 起動**: skill 内で別 skill を Skill tool 経由
   invoke → ユーザが個別に呼ばなくて済む

3 つを組み合わせると「ユーザは方針判断と承認だけ」の状態に近づく。

### refactor 粒度の判断軸

機械的に「全 commit で review」は過剰。「ある unit (Phase) を完結
させてから review」が適切。**作業量と review コストの釣合い** を
見て決める:

- TDD red/green/refactor (1 commit): 数行 → review 不要、最小 diff だから
- Doc unit (1 doc commit): 数百行 → 部分的 review (audit) のみ
- **Phase (10-20 source commits)**: 数千行 → full review (audit + simplify
  + security)
- Release (Phase 14, v0.1.0): 全コードベース → 公開前 deep review

「過剰判定」を恐れず、Phase 単位なら `simplify` + `security-review` を
回しても 1 セッション数分。むしろやらないと chunk-level の
quality gap が貯まる。

### 旧 FromScratch との比較

| 観点                       | 旧 FromScratch              | 本プロジェクト                     |
|---------------------------|------------------------------|------------------------------------|
| permission default         | `default` (都度 prompt)     | `acceptEdits` (Edit auto)          |
| reference clone read      | `/add-dir` 都度実行         | `additionalDirectories` 固定        |
| handover の load          | Claude が手動 Read           | SessionStart hook で auto-print     |
| 次タスクの判定            | ユーザが指示 / Claude 推測    | skill `continue` が ROADMAP §9.<N> から決定 |
| Phase 完了の review        | ユーザが個別 invoke         | skill `continue` が auto chain      |
| 停止点                     | 各 commit / 各 prompt       | 初回 go / Phase 境界 / push のみ    |

**結果**: 本プロジェクトは「continue で Phase が進む、ユーザは要所で
方針判断」の形。旧 FromScratch の「都度確認」モードから前進。
