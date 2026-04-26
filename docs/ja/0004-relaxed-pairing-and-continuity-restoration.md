---
commits:
  - 5750e91
date: 2026-04-27
scope:
  - scripts/check_learning_doc.sh
  - .claude/skills/code-learning-doc/SKILL.md
  - .claude/commands/continue.md (new)
  - .dev/handover.md (restored)
  - .dev/README.md
  - .dev/ROADMAP.md (§9.3 expanded, §12, §13, §17 removed)
  - CLAUDE.md
  - docs/ja/0001-project-bootstrap.md (commit → commits)
  - docs/ja/0002-audit-and-scaffolding.md (同上)
  - docs/ja/0003-self-review-and-iteration-cycle.md (同上)
related:
  - ROADMAP §9.3 (Phase 1 expanded task list)
  - ROADMAP §12 (commit discipline + commit pairing rewritten)
  - ROADMAP §11.6 #1 (gate updated)
---

# 0004 — ペアリング緩和、§17 撤廃、「続けて」自律性の復元

直前の対話レビューで挙がった 4 つの懸念に応じて、運用を一気に改善する
イテレーション。コードベース外 (ガード / 計画 / プロセス) の変更だが、
Phase 1 着手目前のいま **入れておかないと自律開発がブレる** 性質のもの。

---

## 背景 (Background)

### 4 つの懸念 (対話の要点)

1. **1 commit が長大になりすぎる**
   - 旧ルール「1 source = 1 doc」だと、TDD の red/green/refactor を意味のある最小単位で切ろうとしたとき、無理に 1 コミットへ詰める逆効果が出る
   - 旧 v1 ClojureWasm でもこの兆候があった
2. **ベンチマーク早期準備の roadmap への配置**
   - 既に ROADMAP §11.6 #7 と §10.2 に書かれているが、実物 (`bench/quick.sh`) はまだない
   - Phase 1 task list に `[ ] 1.11 bench/quick.sh` として落とし込めば忘れない
3. **ROADMAP §17 改訂履歴の必要性**
   - 「何が変わったか」は `git log -- .dev/ROADMAP.md` で取れる
   - 「なぜ」は該当 ja doc / ADR にある
   - §17 を保守すると drift する。維持コストに見合わない
4. **「続けて」だけで自律開発が走る状態か?**
   - zwasm / v1 ClojureWasm はこの状態 (memo + roadmap で task が一意)
   - 今は ROADMAP §9 が Phase レベル table のみ。Phase 内 task が一意に決まらない
   - handover.md も削除した (空 stub だったため正しい判断だが、Phase 1 に入る瞬間に必要になる)
   - `/continue` のような明示的 entry point もなかった

### LLM 主導開発の「続けて」挙動の依存先

セッション開始時に Claude が読むものは:
- **必ず**: CLAUDE.md (project memory、auto-load)
- **必要に応じて自発的に**: ROADMAP, decisions/, git log

「続けて」と言われたとき次タスクに辿り着くためには、CLAUDE.md に
「**手順**」が書かれていて、それが指す先 (`handover.md`, ROADMAP §9.X)
が **存在し最新** である必要がある。1 つでも欠けると Claude は迷う。

---

## やったこと (What)

### 5750e91 — 改善バンドル (1 source commit のみ)

非 source な変更だけなのでゲート的には source-bearing にカウントされず、
本ファイルは voluntary doc として 5750e91 を `commits:` に列挙する。

#### (1) ゲート緩和: 多数 source commit → 1 doc commit

`scripts/check_learning_doc.sh` を書き換え、Rule 2 を「直前 doc から
unpaired な source SHA すべてを doc が `commits:` で覆っているか」に変更。

```
旧: source N → doc N+1 → source N+2 → doc N+3   (常に交互必須)
新: source N → source N+1 → ... → source N+k → doc N+k+1
                                                 ↑ commits: [N..N+k]
```

これで **1 unit of work = 多数の小さな source commits + 1 doc** の自然な
リズムを取れる。red / green / refactor をそれぞれコミットしても、Phase
末で 1 つの物語として doc に書ける。

副次的に、doc commit 検出を `--diff-filter=A` (新規追加のみ) に絞り、
**既存 doc の typo 修正 commit が誤って doc commit と判定される bug** も
潰した。

#### (2) ROADMAP §9.3: Phase 1 task list を inline 展開

旧 FromScratch は `.dev/roadmap.md` に Phase ごと task list を持っていた。
本プロジェクトは ROADMAP §9 を summary table のみにしていたため、Phase
内の「次タスク」が一意に決まらなかった。

```
| Task | Description                            | Status     |
|------|----------------------------------------|------------|
| 1.0  | Build skeleton + flake.nix + main.zig  | [x] 116b874 |
| 1.1  | src/runtime/value.zig (NaN boxing)     | [ ]        |
| 1.2  | src/runtime/error.zig                   | [ ]        |
| ...  | ...                                    | [ ]        |
| 1.11 | bench/quick.sh (microbenchmarks)        | [ ]        |
| 1.12 | 🔒 x86_64 Gate                          | [ ]        |
```

ベンチ早期準備 (1.11) と x86_64 ゲート (1.12) を **task として明示**。
これで「忘れる」を構造的に阻止。Phase 2 以降は §9.4 等に **そのフェーズ
着手時に展開** する (前 phase 完了が条件)。

#### (3) §17 改訂履歴の撤廃

§17 を section ごと削除。preamble の Note に「history は git log + ja
docs + ADRs にある」と記載。TOC の §17 行も削除。

#### (4) handover.md を load-bearing に復活

「create on demand」だったが、Phase 1 着手目前のいま実体が必要なので
作成。フォーマットは前回 commit 3 で削除したものとほぼ同じだが、
**最低限の sections** に絞った:
- Current state (Phase + branch + last paired commit + build)
- Unpaired source commits (= 次の doc commit が拾うべき SHA)
- Next task (§9.X の task 番号 + exit criterion)
- Open questions / blockers
- Notes for next session

`.dev/README.md` から「on demand」リストから削除し、「always present
load-bearing」リストへ昇格。

#### (5) `.claude/commands/continue.md` (新規 slash command)

`/continue` で次のシーケンスを起動:
1. handover.md 読む
2. ROADMAP §9 で IN-PROGRESS phase + 次の `[ ]` task 特定
3. `git log --oneline -10` で unpaired source commits を確認
4. `bash test/run_all.sh` で build green 確認
5. 5-8 行のサマリ (phase / last commit / test status / unpaired SHAs / next task)
6. **ユーザの "go" 待ち** (主体的に走り出さない)

#### (6) CLAUDE.md 「Iteration loop」強化

`## Iteration loop (resume / 「続けて」procedure)` 節を追加。1-5 の
具体的手順 + per-task TDD loop を明文化。Claude が initial CLAUDE.md
読み込みだけで「続けて」を解釈できるようにする。

#### (7) frontmatter 移行: `commit:` → `commits:`

0001 / 0002 / 0003 の frontmatter を `commit: <sha>` から
`commits: [<sha>]` (block 形式) に統一。新ゲートのパーサが
`commits:` のみを見るため。単一要素 list は valid。

---

## コード (Snapshot)

### 新ゲート Rule 2 中核 (`scripts/check_learning_doc.sh`)

```bash
# Walk back from HEAD collecting unpaired source-bearing SHAs (oldest first).
# Stop at the first commit that itself added a learning doc; everything at
# or before it is paired.
expected="$(python3 - "$new_doc_path" <<'PY'
shas = subprocess.run(["git", "log", "--format=%H", "HEAD"],
    capture_output=True, text=True).stdout.splitlines()
unpaired = []
for sha in shas:
    if added_doc(sha):
        break
    files = commit_files(sha)
    if any(is_source(f) for f in files):
        unpaired.append(sha[:7])
print("\n".join(reversed(unpaired)))
PY
)"

# Verify: every expected SHA appears in covered (commits: list)
missing=""
while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  if ! grep -qx "$sha" <<< "$covered"; then
    missing="${missing}${sha} "
  fi
done <<< "$expected"

if [[ -n "$missing" ]]; then
  cat >&2 <<EOF
✗ Missing from \`commits:\`: ${missing}
EOF
  exit 1
fi
```

### `.claude/commands/continue.md` (要点)

```markdown
1. Read .dev/handover.md
2. Read .dev/ROADMAP.md §9 — find IN-PROGRESS phase + first [ ] task
3. git log --oneline -10 — identify unpaired source SHAs
4. bash test/run_all.sh — confirm build is green
5. Summarise (Phase / Last commit / Tests / Unpaired SHAs / Next task)
6. Wait for the user's "go"
```

### Phase 1 task list (`.dev/ROADMAP.md` §9.3)

```
| 1.0  | Build skeleton + flake + main.zig    | [x] 116b874 |
| 1.1  | src/runtime/value.zig (NaN boxing)    | [ ]         |
| 1.2  | src/runtime/error.zig                  | [ ]         |
| 1.3  | src/runtime/gc/arena.zig               | [ ]         |
| 1.4  | src/runtime/collection/list.zig        | [ ]         |
| 1.5  | src/runtime/hash.zig                   | [ ]         |
| 1.6  | src/runtime/keyword.zig                | [ ]         |
| 1.7  | src/eval/form.zig                      | [ ]         |
| 1.8  | src/eval/tokenizer.zig                 | [ ]         |
| 1.9  | src/eval/reader.zig                    | [ ]         |
| 1.10 | src/main.zig (-e flag, read+print)     | [ ]         |
| 1.11 | bench/quick.sh microbenchmarks         | [ ]         |
| 1.12 | 🔒 x86_64 Gate                         | [ ]         |
```

---

## なぜ (Why)

### ゲート緩和 vs 維持

| 観点                          | 旧 (1:1 強制)               | 新 (n:1 緩和)                   |
|------------------------------|-----------------------------|----------------------------------|
| commit 単位の自然さ           | 強制で歪む                   | 自然 (red/green/refactor 別 OK) |
| doc の物語性                  | 1 commit ごとで断片的         | unit of work 単位で読める        |
| commit 数                     | 倍 (source + doc)            | source N + 1 doc                |
| `commits:` 管理               | 単一 SHA、ミスしようがない    | リスト、抜け漏れリスク           |
| ゲート実装                     | 簡単 (HEAD 直前を見る)        | やや複雑 (HEAD から walk back)  |
| 規律としての強度               | 強                            | 中 (無限に source 積む可能性)   |

新方式の弱点 = "doc 書かずに source 積みっぱなし" のリスク。これは
ゲートでなく **handover.md の "Unpaired source commits" 欄** で見える化
することで対応する。`/continue` がそれを必ず summary に出す。

### §17 撤廃の判断

- §17 を維持すると、ROADMAP 編集のたびに「§17 にも 1 行書いた?」と
  チェックが必要 → 結局忘れる → §17 が嘘をつく
- `git log -- .dev/ROADMAP.md` の方が正確 + 自動更新
- 大きな方針転換は ADR、小さな改善は ja doc に出てくる
- → §17 は **形式的な維持コスト > 価値**

### handover.md 復活の判断

- 旧 commit 3 で削除したのは正解 (空 stub だった、`docs/README.md` も同様)
- 今復活するのは **実質的な内容ができたから** (Phase 1 に入る前の状態 + next task)
- これからは Phase の進行と共に常に最新化される。空にならない
- 「on demand」リストから外し「load-bearing」へ昇格

### `/continue` slash command の位置付け

- skill (description-trigger) でも実装可能だが、**user が明示的に呼ぶ** 方が「続けて」の意図と一致する
- skill だと description マッチで意図しない時に発動する可能性
- slash command は user が打鍵 → 確定的にトリガ
- 結果: `/continue` で確定起動、`「続けて」` は CLAUDE.md の手順を Claude が解釈、どちらでも到達

---

## 確認 (Try it)

### ゲート: 多数 source + 1 doc が通ること

```sh
# 仮想シナリオ:
git commit -m "feat: A"   # SHA_A (source)
git commit -m "feat: B"   # SHA_B (source)
git commit -m "feat: C"   # SHA_C (source)
# ここで doc を書く
$EDITOR docs/ja/0099-feature.md
# frontmatter:
#   commits:
#     - <SHA_A>
#     - <SHA_B>
#     - <SHA_C>
git add docs/ja/0099-feature.md
git commit -m "docs(ja): 0099 — feature (#A..C)"
# ゲート: walk back, expected = [A, B, C], covered = [A, B, C], pass
```

### ゲート: doc が SHA を 1 つ抜かしたら block

```sh
# 上のシナリオで commits: 内に SHA_B を書き忘れた場合
✗ commit blocked by scripts/check_learning_doc.sh (Rule 2)
The learning doc docs/ja/0099-feature.md does not cover every
unpaired source commit.
Missing from `commits:`: SHA_B
```

### `/continue` シナリオ (Phase 1 着手時に新セッションで)

ユーザ: `/continue`

Claude (期待される応答):
```
- Phase: 1 (Value + Reader + Error + Arena GC)
- Last commit: <hash> docs(ja): 0004 — relaxed-pairing-and-continuity-restoration
- Test status: green
- Unpaired source commits: (none)
- Next task: §9.3 / 1.1 — src/runtime/value.zig (NaN boxing Value type, HeapTag, HeapHeader).
  Exit criterion: Value.initInteger(42) round-trips through tag(); encodeHeapPtr(.string, ...) reads back as .string.
Ready to start when you say go.
```

---

## 学び (Takeaway)

### 自律開発インフラ設計の知識

- **ルールの強度は段階的に決める**: 「1:1 強制」と「無制限」の中間として
  「unit of work で doc が必ずカバーする」を設計できる。後者は
  developer の判断に余地を残しつつ、抜け漏れは機械的に検出する
- **§17 のような "維持必須メタデータ" は drift する**: 自動生成できる
  もの (git log) を手動 maintain するのは ROI 負。撤廃判断は早い方がよい
- **「常時ロード」「path-matched ロード」「ロード on demand」「user 明示
  invocation」の 4 層**: それぞれ trigger 性質が違う。常時 = CLAUDE.md
  (高頻度参照ルール)、path-matched = `.claude/rules/*` (編集対象に応じた
  リマインダ)、on demand skill = 特定アクション、user invocation = slash
  command。役割が重複しないよう配分するのが綺麗
- **`/continue` を入れる意義**: zwasm / v1 で「memo + roadmap で続けて」
  が成立していたのは、memo / roadmap の format が安定していたから。
  本プロジェクトは format がまだ安定途上 (Phase 1 が始まっていない) なので、
  **手順を明示的に slash command 化** して安定化を待たずに自律性を確保

### shell / git 知識

- **`--diff-filter` の使い分け**: ACMR (added/copied/modified/renamed) で
  「触ったすべて」、A だけで「新規追加だけ」。ゲートロジックでこれを
  混同すると「typo 修正コミットが doc commit と誤判定」のような subtle
  bug を生む
- **bash `case` での glob 順序の罠**: より specific な pattern を先に置く。
  `0000-*.md` を `[0-9][0-9][0-9][0-9]-*.md` の前に書いて template を除外
  したように、**順序こそ semantic**

### Process design の知識

- **「コミット粒度」は道具立てで決まる**: ゲートが 1:1 を強制するか n:1 を
  許すかで、developer の commit 行動は劇的に変わる。process design は
  tooling design とほぼ同義
- **handover の存在 == 自律性**: 「次に何をするか」が 1 ファイルから取れない
  限り、新セッションは必ず人間に聞きに来る。逆に、その 1 ファイルを保証
  すれば「続けて」だけで走る
- **「忘れない」を構造化する**: TODO リストではなく ROADMAP の Phase task
  inline 展開 + Quality gate timeline 表 + ゲート script の 3 層構成。
  どれか 1 つでは脆い、3 つあって初めて「機械的に思い出される」
