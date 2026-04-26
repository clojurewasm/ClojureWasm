---
commit: TBD (このコミット直後に SHA を埋める)
date: 2026-04-27
scope:
  - build.zig
  - build.zig.zon
  - flake.nix
  - src/main.zig
  - CLAUDE.md
  - README.md
  - LICENSE
  - .gitignore
  - .envrc
  - .editorconfig
  - .claude/settings.json
  - .claude/skills/code-learning-doc/SKILL.md
  - .dev/README.md
  - .dev/ROADMAP.md
  - docs/README.md
  - docs/ja/README.md
  - scripts/check_learning_doc.sh
related:
  - ROADMAP §1 (Mission), §2 (Principles), §5 (Layout), §12 (Commit discipline)
---

# 0001 — プロジェクトブートストラップ

ClojureWasm の `cw-from-scratch` ブランチで、白紙状態から **自律開発と
学習の両輪を回す土台** を組む最初のコミット。Zig 0.16.0 / Nix / Claude Code
を統合し、後続の Phase 1 以降が同じ要領で積み重ねられる「型」を据える。

---

## 背景 (Background)

### なぜ ClojureWasm v2 を白紙から組み直すのか

v1 (89K LOC, v0.5.0) で **feature-rich** な Clojure ランタイムが既に動いている。
にもかかわらず、本ブランチ `cw-from-scratch` では `main` (= v0.5.0) から派生して
ソースをすべて削除し、改めて積み上げ直す。理由:

- 「**理解しながら進める**」(ROADMAP §2 P1) を最優先にしたい
  → 一晩 LLM 自動実行で大量に積むのではなく、各コミットを「読める」単位にする
- v1 で見えた **設計の歪み** (NaN boxing 後付け / threadlocal 散在 /
  collections.zig 6K LOC / nREPL 密結合 / pod system 不在) を Day 1 から回避
- **edge / Wasm Component** を first-class にする差別化 (ROADMAP §1.2)。
  v1 は native ランタイムから Wasm を呼ぶ方向のみで、自分自身が Wasm component
  になる道は未着手だった
- **commit ごとに学習ノートが残る公開リポジトリ** という形 (= 本ファイル)
  そのものを Conj 発表 / 技術書の素材にする

### なぜ Zig 0.16.0 か

- **`std.Io` の DI 哲学** が Clojure ランタイムの並行性設計と相性が良い
  (atom / agent / future / promise を `std.Io.Mutex` + `std.Io.async` に綺麗に
  対応付けられる、ROADMAP §7.1)
- **Juicy Main** (`pub fn main(init: std.process.Init)`) が io / arena / gpa /
  args / preopens / environ_map を bundle で受け取れ、グローバル変数を作らずに
  Runtime ハンドルへ流し込める
- **`*std.Io.Writer`** という単一の type-erased writer が `anytype` の
  「inferred error set 解決不能」問題を解消。Reader/Printer の interface 設計が
  軽くなる
- **packed struct(u8) のビット指定**、**`@embedFile`** (core.clj 直埋め込み)、
  **comptime StaticStringMap** (opcode/keyword テーブル) など、処理系実装に
  ぴったりの comptime 機構

### なぜ Nix flake (`zig-overlay` 経由)

- Zig は CI / クロスプラットフォームで **toolchain version pinning** が品質に
  直結 (NaN boxing / packed struct alignment / opcode dispatch は arch 依存性が
  出やすい)
- `zig-overlay` (`github:mitchellh/zig-overlay`) は 0.16.0 を含む全リリースを
  hash-pinned で提供。`fetchurl` + 手書き SHA256 より保守容易
- `direnv` + `.envrc` (`use flake`) で「ディレクトリに入った瞬間に Zig 0.16.0」
  が保証される

---

## やったこと (What)

このコミットで 17 ファイルを追加 / 差し替え:

**ビルド・dev shell**
- 新規: `build.zig` (Zig 0.16 idiom: `b.createModule` + `addExecutable`)
- 新規: `build.zig.zon` (`name = .cljw`, fingerprint, min Zig 0.16.0)
- 新規: `flake.nix` (zig-overlay + hyperfine + yq-go)
- 新規: `.envrc` (`use flake`)
- 新規: `.editorconfig`
- 新規: `.gitignore` (`zig-out/`, `.zig-cache/`, `private/`,
  `.claude/settings.local.json` ほか)

**ソース**
- 新規: `src/main.zig` (Juicy Main で stdout に "ClojureWasm" を 1 行)

**プロジェクトドキュメント (英語)**
- 新規: `README.md`
- 新規: `CLAUDE.md` (Identity / Context 節を冒頭に置き、Claude Code が必ず読む)
- 新規: `.dev/README.md`
- 新規: `.dev/ROADMAP.md` (17 セクション、唯一の権威ある計画書)
- 新規: `docs/README.md`

**学習ノート機構**
- 新規: `docs/ja/README.md`
- 新規: `.claude/skills/code-learning-doc/SKILL.md` (skill 定義、雛形)
- 新規: `scripts/check_learning_doc.sh` (commit gate)

**Claude Code 設定**
- 新規: `.claude/settings.json` (permissions + `PreToolUse` hook 配線)

**ライセンス**
- 差し替え: `LICENSE` を MIT → **EPL-2.0** (Clojure エコシステム慣例。詳細は §なぜ)

---

## コード (Snapshot)

将来上書きされる前提で、いま動いている重要部分を凍結する。

### `src/main.zig`

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("ClojureWasm\n");
    try stdout.flush();
}

test "smoke: main module loads" {
    try std.testing.expect(true);
}
```

### `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "cljw",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
```

### `build.zig.zon`

```zon
.{
    .name = .cljw,
    .version = "0.0.0",
    .fingerprint = 0x1869d207073beffa,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "LICENSE",
        "README.md",
    },
}
```

### `.claude/settings.json` (hook 配線部のみ)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash $CLAUDE_PROJECT_DIR/scripts/check_learning_doc.sh"
          }
        ]
      }
    ]
  }
}
```

### `scripts/check_learning_doc.sh` (発動条件部)

```bash
# Only enforce on `git commit`
if ! printf '%s' "$COMMAND" | grep -qE '(^|[ ;&|])git[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# Source-bearing patterns that require a doc
needs_doc=0
while IFS= read -r f; do
  case "$f" in
    src/*.zig|build.zig|build.zig.zon|.dev/decisions/*.md)
      needs_doc=1
      break
      ;;
  esac
done <<< "$STAGED"
```

---

## なぜ (Why)

### 設計判断と却下案

**1. プロジェクト名: ClojureWasm (作業ディレクトリは ClojureWasmFromScratch のまま)**
- 採用理由: 公開アーティファクト名・docs・バイナリ名はすべて `ClojureWasm`
  に統一。git remote も `clojurewasm/ClojureWasm`。「FromScratch」は単に
  「v1 のリポジトリと同じディスク上の場所で衝突しないため」だけの作業ディレクトリ命名
- 却下案: ディレクトリも ClojureWasm に rename → v1 reference clone と衝突するため不可

**2. ライセンス: EPL-2.0 (MIT から差し替え)**
- 調査結果: Clojure 本家 / Babashka / SCI / spec.alpha = EPL-1.0、新しめの
  Malli = EPL-2.0、Eclipse Foundation は EPL-1.0 を deprecated として 2.0 を推奨
- 採用理由: **Clojure エコシステムへの帰属を明示** (MIT だと「Clojure 系
  ではない別ジャンル」に見える)、かつ EPL-2.0 は Eclipse Foundation 推奨で
  GPL-2.0+ 互換 secondary license オプション付き
- 却下案 1: EPL-1.0 (本家追従) → 新規プロジェクトで deprecated を選ぶ理由なし
- 却下案 2: MIT (JUXT が「ライブラリには MIT」を提唱) → ランタイム本体は
  ライブラリではないので慣例優先

**3. Juicy Main + Runtime ハンドルへ io を流す**
- 採用理由: `std.process.Init` から `init.io` を取り、後続のコードに値渡し。
  グローバル変数を作らない。Phase 2 以降に `Runtime` 構造体に格納し、
  `keyword.intern(rt, ns, name)` 等が `rt.io` を経由して `std.Io.Mutex.lock(io)`
  できる
- 却下案: グローバル `var io: std.Io = undefined` → テスト時 mock 不可、
  multi-tenant 不可、0.16 の DI 哲学に反する

**4. `docs/ja/NNNN-*.md` を hook で必須化**
- 採用理由: 「コードはどんどん上書きされる」のでスナップショットを残す
  仕組みが必要。ad-hoc 運用だと書き忘れる → CI / pre-commit で物理的に強制
- 却下案 1: git pre-commit hook (`.git/hooks/pre-commit`) → tracking 不可、
  個人環境ごとに setup 必要
- 却下案 2: ロード時に CLAUDE.md で指示するだけ → 強制力ゼロ、忘却必至
- 採用形: Claude Code `PreToolUse` hook on `Bash` matcher、stdin で
  `tool_input.command` を解析し `git commit` のみで発動。プロジェクトに
  `.claude/settings.json` で配線するので clone 直後から有効

**5. 学習ノートの言語: 日本語**
- 採用理由: ユーザの母語 + 思考言語。コードを読む人に日本語の解説が並ぶことで
  「なぜそうなっているか」を最も自然に書ける。技術書化したときも素材として
  即使える
- ただしコード本体・README・ROADMAP・ADR は **公開先に向けて英語** (CLAUDE.md
  Language policy 節)

### ROADMAP § / 原則との対応

- §2 P1 (理解しながら進める) → 学習ノートゲートそのもの
- §2 P2 (完成形を Day 1 で見通す) → ROADMAP §5 のディレクトリ完成形を Day 1 確定
- §2 P9 (one task = one commit) → CLAUDE.md / ROADMAP §12 で明文化
- §2 P10 (Zig 0.16 idiom) → Juicy Main / std.Io.File / packed struct(u8) を
  Day 1 採用
- §2 A1 (zone 厳守) → `scripts/zone_check.sh` 雛形を Phase で導入予定 (このコミット
  時点ではまだない)
- §12.2 (commit-snapshot doc gate) → 本ファイルがその第 1 号

---

## 確認 (Try it)

このコミット時点で動かして観察できること:

### ビルド・実行・テスト

```sh
zig version
# 0.16.0

zig build
# (no output, success)

zig build test
# (no output, success — smoke test passes)

zig build run
# ClojureWasm
```

成果物:

```sh
ls zig-out/bin/
# cljw*
```

### Commit gate のセルフテスト

新しい commit を試みた時、`docs/ja/NNNN-*.md` を伴わない `src/` 変更がブロック
されることを確認:

```sh
# 何かしら src/ を編集して staging
echo "// touch" >> src/main.zig && git add src/main.zig

# git commit を Claude 経由で叩く → ブロック
# (直接 shell で git commit すると hook は発動しない、Claude Code 経由のみ)
echo '{"tool_input":{"command":"git commit -m test"}}' \
  | bash scripts/check_learning_doc.sh
echo "exit=$?"
# ✗ commit blocked by scripts/check_learning_doc.sh
# Source-bearing files are staged but no new docs/ja/NNNN-<slug>.md was added.
# Next index to use: 0002-<slug>.md
# exit=1

# cleanup
git restore --staged src/main.zig
git checkout src/main.zig
```

---

## 学び (Takeaway)

将来の自分 (技術書執筆 / 発表 / 後続セッション) に渡したいポイント:

### 処理系実装の一般知識

- **白紙コミットから始める意味**: feature-rich な v1 がある状態でも、
  v2 は「v1 で得た理解を初手から構造に焼き込む」場として独立した価値がある。
  「捨てる」のではなく「2 周目を回す」
- **コミットスナップショット文書化**: 処理系コードは TreeWalk → VM、Reader 拡張、
  optimizer 追加で激しく上書きされる。各時点の「なぜそうなっているか」を文章化
  しておくことは、後続フェーズの自分が一番恩恵を受ける
- **Tier 制 + pod システム**: アドホック互換実装の沼を物理的に阻止する仕組み。
  「ライブラリを動かすために既存コードに分岐を入れる」を制度上禁止し、ADR or pod
  に escalate させる

### Zig 0.16 知識

- **Juicy Main** (`pub fn main(init: std.process.Init)`) は 0.16 で追加された
  「全部入り main」シグネチャ。`init.io` (std.Io)、`init.arena` (process-lifetime
  arena)、`init.gpa` (thread-safe GeneralPurposeAllocator) が同時に渡される。
  Compile-time に main の引数型でディスパッチされる (`std/start.zig:696-703`)
- **`std.Io.File.stdout().writer(io, &buf)`**: 0.16 では writer に **`io` 引数が
  必須** (0.15 までは不要だった、0.16 で signature が変わった)。dev shell で
  `zig build` がコケた時はまずここを疑う
- **`*std.Io.Writer`**: 0.16 で `std.io.AnyWriter` を置き換えた type-erased writer。
  recursion で「unable to resolve inferred error set」を回避するための選択肢
- **`build.zig.zon` の fingerprint**: package 名から決定的に上位 32bit が
  derive される。間違ったまま書くと zig がエラーで「正しい値はこれ」と教えて
  くれるので、それを貼り付ける
- **`packed struct(u8)`**: bit 単位のレイアウト指定。`HeapHeader.flags` のように
  GC の mark / frozen を 1 byte に詰める用途に最適 (詳しくは Phase 1.2 で扱う)

### Claude Code 知識

- **Project skill** は `.claude/skills/<name>/SKILL.md` で定義。frontmatter の
  `description` がトリガ条件。skill discovery は description のセマンティクス
  マッチで起動される
- **Hook (PreToolUse)** は stdin に JSON で `tool_input` を受け取る。
  Bash matcher で全 Bash 呼び出しを intercept できるが、コマンド本体を見て
  自前で「git commit のみ反応」を仕分けるのが堅実
- **`$CLAUDE_PROJECT_DIR`** はフック実行時にプロジェクトルートを指す環境変数。
  hook script からプロジェクト相対パスを解決するときに使う
- **Identity / Context 節 の冒頭設置**: 同じ親ディレクトリに「同じ git remote の
  別 clone」が複数あるような状況では、CLAUDE.md の冒頭で「ここで commit する」
  「あの clone は read only」を明示する。Claude が混同して別の repo に commit
  しに行く事故を防げる

### Clojure エコシステム知識

- **EPL-2.0**: Eclipse Public License の現行版 (2017〜)。EPL-1.0 と機能はほぼ
  同じだが、(1) 「ファイル」を「モジュール」と言い換え、(2) GPL-2.0+ の
  secondary license オプション、(3) 「choice of law: New York 州」の削除、
  という 3 点が改善
- **Clojure 本家 (= Rich Hickey 系) は EPL-1.0**: 2009 年の選択を維持。
  本家ライブラリ (clojure / spec.alpha / core.async) は今も EPL-1.0
- **新規 Clojure 系プロジェクトは EPL-2.0 を選ぶことが多い**: Eclipse Foundation の
  推奨に従う。Malli (metosin 系) は EPL-2.0
- **Babashka / SCI は EPL-1.0**: SCI が Clojure 本家コードを参照していて
  ライセンス互換性を厳密に揃えるため
- ClojureWasm v2 は **EPL-2.0** を採用 (新規 / Clojure エコシステム帰属を表明 /
  Eclipse Foundation 推奨)
