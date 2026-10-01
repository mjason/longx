# Longx

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

エージェントを、プロジェクトの一部に。

Longx は、会話、ファイル、コマンド、Git をひとつにまとめるローカル優先の
エージェントワークスペースです。好きなモデルプロバイダーに接続できます。
その中心にあるのは、エージェント開発をプロジェクトの活動として扱い、
動作を確認・変更・バージョン管理・共有できるようにするという考え方です。

![Longx ワークスペース](docs/media/session.png)

## インストール

Linux x86_64 / arm64：

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/longx/main/install.sh | sh
```

`http://<host>:7788` を開き、「Settings → Providers」でモデルを設定して、
プロジェクトの作業ディレクトリを追加してください。
リリースには Erlang ランタイムと UI が含まれ、開発ツールチェーンは不要です。
glibc ≥ 2.39（Ubuntu 24.04、Debian 13 以降）が必要です。Git 機能には `git` が必要です。

[インストール・Docker・HTTPS・更新（English）](docs/installation.md) ·
[Releases](https://github.com/mjason/longx/releases)

> Longx はコマンドをサンドボックス化しません。コマンドは Longx を実行する OS ユーザーの
> 権限で動きます。隔離が必要な場合は、アプリ全体をコンテナや専用環境で実行してください。

## エージェント開発はプロジェクトに属する

役に立つエージェントには、良いプロンプトだけでなく、プロジェクトのツール、
作業規約、レビュー方針、役割分担、そして経験から得た知識が必要です。

Longx の中心的な違いは、それらの置き場所です。**プロジェクトの中に置きます。**
今日うまくいったワークフローを、会話履歴や一人の開発者のマシン設定だけに残しません。
ファイルにして、レビューし、コミットする。次の開発者も、次のマシンも、そこから続けられます。

```text
your-project/
├── AGENTS.md                  # プロジェクトの指示
├── .agents/skills/            # SKILL.md と参考資料
└── .longx/
    ├── agent.exs              # 共有するエージェント定義
    ├── shared/                # バージョン管理する動作・役割・知識・定期処理
    │   ├── plugs/
    │   ├── agents/
    │   ├── knowledge/
    │   └── watches/
    └── local/                 # マシン固有の実験と上書き
```

実験は gitignore する `.longx/local/` から始めます。
役に立つ動作になったら、レビューして `shared/` へ移します。
共有定義はリポジトリと一緒に移動し、認証情報やプロバイダー設定は含めません。
別のマシンで同じモデルエイリアスを設定すれば、同じ定義を再利用できます。

## 記憶を、自分で管理できる知識にする

残す価値のあるものは、ただ「覚える」のではなく、書き残します。

Longx の長期記憶は Markdown の知識文書です。エージェントは作業中に有用な決定、
手順、経験を記録します。人が読み、古くなった内容を直し、差分をレビューして、
プロジェクトに共有できます。新しい会話でも、学んだ時の会話を再生せずに知識を利用できます。

| 範囲 | 誰に属するか |
| --- | --- |
| `local` | このプロジェクトのマシン固有のメモ。エージェントの標準の書き込み先 |
| `project` | `.longx/shared/knowledge/` のレビュー済みチーム知識。プロジェクトと一緒にバージョン管理 |
| `global` | 個人の好みとマシンに関する知識。プロジェクト間で利用 |
| `longx` | Longx に同梱された読み取り専用のガイド |

知識文書はトピックごとに整理し、タイトルと要約を付けます。
エージェントは小さなトピック索引を見て、`knowledge_read` / `knowledge_search` で
関連文書を取得し、`knowledge_write` で維持します。
`always: true` を付けた短い必須文書だけを、容量の上限内で直接コンテキストに含めます。

例えば、レビュー済みの `.longx/shared/knowledge/testing/checks.md`：

```markdown
---
title: Verification workflow
summary: Checks to run before accepting a change
tags: [testing]
always: false
---

Run the relevant tests, then the full project checks before reporting completion.
```

まず `local` に蓄積し、役に立つメモをレビューして `project` へ移します。
知識はガイドであり、現在の事実の証明ではありません。変わり得る内容はコードで確認し、
古くなった文書を更新します。会話履歴は出来事の記録、コンテキスト圧縮は会話を続けるためのものです。
どちらも、維持して会話を越えて再利用する知識の代わりにはなりません。

[記憶の使い方と維持（English）](docs/memory.md)

## 透明なエージェントを、コードで定義する

Longx の定義は普通の Elixir ファイルです。指示、ツール、役割、ループ方針を
読んで変更できます。エージェント自身も変更を提案できますが、
どれを共有コードにするかは人が決めます。

```elixir
# .longx/agent.exs
import Longx.Agent.Config

agent do
  version 1
  extends :default
  model "pro"                    # Settings で設定したエイリアス
  prompt "Verify changes with the project's tests."
  plug ReviewOnce
end
```

`extends :default` は標準の動作を保ち、プロジェクトの差分を重ねます。
`plug` で追加、`options` で設定、`drop` で削除できます。Longx を fork する必要はありません。

コードを確認してから、プロジェクト設定で `.longx` の定義を信頼して読み込む設定を有効にします。
この設定は clone で届いた共有コードを対象とし、`local/` は常に読み込まれます。
変更は次のエージェント step で反映され、アプリの再起動は不要です。
読み込みエラーはエージェントに通知されます。

### 読んで変更できるループ

終了しようとするエージェントに、一度だけ追加のレビューを依頼する plug です：

```elixir
# .longx/shared/plugs/review_once.exs
defmodule ReviewOnce do
  use Longx.Agent.Plug

  def call(%Step{phase: :turn_end} = step, _opts) do
    if Map.get(step.state, :review_once_requested, false) do
      step
    else
      step
      |> Step.put_state(:review_once_requested, true)
      |> Step.continue("""
      Review your changes against the original request.
      Run any missing checks, fix issues you find, then report the result.
      """)
    end
  end

  def call(step, _opts), do: step
end
```

状態は同じターンの後続 step に保持され、次のターンでリセットされます。
そのため追加レビューは最大一回です。これはレビュー方針であり、正しさの証明ではありません。
テストなどの決定的なチェックで結果を検証してください。

Plug の三つのフェーズは、指示とツールを組む `:request`、実行前のツール呼び出しを見る
`:response`、続行を決める `:turn_end` です。ループ方針はプロジェクトのコードになり、
実行・メッセージ・中断は既存の runtime が扱います。

## OTP を最大限に再利用する

長く動き続ける並行エージェントには、OTP が最適な基盤だと考えています。
Longx はプロセス、状態機械、監督ツリー、task、mailbox を再利用します。

各会話は `:gen_statem` で動く `Longx.Agent` プロセスです。
モデル要求とツール呼び出しは監督される task で実行し、結果はメッセージとして届きます。
子エージェントも、同じ runtime の別プロセスです。

| 作りたいもの | 再利用するもの |
| --- | --- |
| 独自ループ・レビュー方針 | Plug のフェーズ関数、`Step.put_state/3`、`Step.continue/2` |
| プロジェクトのツール | Plug の `tool` 宣言と普通の Elixir 関数。カーネルが task として実行 |
| エージェントチーム | プロジェクトの役割定義と `Step.spawn/4`。報告は mailbox へ |
| ターンを越える仕事 | Jobs や watches。完了時に会話を起こす |

フェーズ関数は短く、ブロックしないようにします。Effects とツールで仕事を表現すれば、
カーネルは追加の指示や停止要求を受け取れます。既存の監督とクラッシュ報告を使ってください。
クラッシュしたエージェントは再起動しますが、中断されたターンは失敗として処理し、
黙って再実行しません。

新しい能力は、まず**既存の runtime を使うプロジェクト plug で表せるか**を考えます。
必要な汎用プリミティブがない場合だけ、カーネルを拡張します。

## 定期処理も、見えるコードにする

定期処理も、それが起こすエージェントと同じように確認できるべきです。
Longx の **watch** は普通のプロジェクトスクリプトです。
スケジュール、チェック、状態、通知条件がすべてコードにあり、
読んで変更し、差分をレビューし、共有できます。

スケジューラーは時計を提供し、スクリプトが何を重要とするか決めます。
チェック自体はモデルを呼びません。スクリプトがメッセージを送った時だけ、
エージェントを起こします。

例えば、依存関係のロックファイルを一時間ごとに確認し、
最初の基準値から変更された時だけレビューを依頼します：

```elixir
# .longx/local/watches/lockfile_watch.exs
defmodule LockfileWatch do
  use Longx.Agent.Watch

  every "0 * * * *"
  max_runs 24

  def run(ctx) do
    content = File.read!(Path.join(ctx.project_root, "mix.lock"))
    revision = :crypto.hash(:sha256, content) |> Base.encode16()
    previous = ctx.state[:revision]

    if previous && previous != revision do
      send(ctx, :self, "The dependency lock changed. Review the update and run the relevant checks.")
    end

    log(ctx, "Dependency lock: #{String.slice(revision, 0, 12)}")
    {:ok, %{revision: revision}}
  end
end
```

返した状態は次の実行に保持されます。この watch は最大 24 回チェックし、
変更がなければモデルを起こしません。`:self` は watch 自身の会話にメッセージを送り、
後続の作業も開いて確認できます。

定期 cron、一度だけの指定時刻、webhook に対応します。
`watch_list` でスケジュール、次の実行、直近の出力、状態、エラーを確認できます。
`watch_run` はログと送信予定のメッセージを表示し、実際には配信しません。
ただしスクリプトのチェックは実行されます。サンドボックスではなく、任意の副作用を戻す機能でもありません。

実験は `local/watches/` に置き、レビュー後にチームの自動化を `.longx/shared/watches/` へ移します。
共有 watch は信頼したプロジェクトで読み込み、別途 `plug` を宣言する必要はありません。
Longx サーバーは動作している必要がありますが、ブラウザーのタブや実行中の会話は不要です。

[Watch・スケジュール・監視の書き方（English）](priv/agent/knowledge/writing-watches.md)

## この働き方を支えるワークスペース

DeepSeek、GLM、Alibaba Cloud Bailian、OpenAI、または OpenAI Responses API 互換サービスを
接続できます。定義にはモデルエイリアスを使い、プロバイダー変更時にコードを書き換えずに済むようにします。

会話、エージェントチーム、実際のファイル、コマンド出力、Git の変更を一緒に扱えます。
デスクトップとモバイルに対応し、[Android シェル](https://github.com/mjason/longx-android)もあります。
アプリの UI は簡体字中国語と英語に対応しています。

<details>
<summary>スクリーンショットと動画</summary>

![プロジェクト一覧](docs/media/welcome.png)

![ファイルと Markdown プレビュー](docs/media/file-preview.png)

[デスクトップ動画](docs/media/tour.webm) · [モバイル動画](docs/media/tour-mobile.webm) ·
[モバイルのワークスペース](docs/media/session-mobile.png)

</details>

## 詳しく読む

- [インストールと運用（English）](docs/installation.md)
- [Plug とプロジェクトの役割（English）](priv/agent/knowledge/writing-plugs.md)
- [Watches（English）](priv/agent/knowledge/writing-watches.md)
- [開発と貢献（English）](docs/development.md)
- [詳細な運用・拡張リファレンス（中文）](docs/reference.zh-CN.md)

Elixir/OTP、Ash、Phoenix、React で構築。[MIT ライセンス](LICENSE)。
