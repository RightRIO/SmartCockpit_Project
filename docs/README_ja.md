# VoYah - インテリジェントコックピット分散タスクスケジューラー

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue)](CHANGELOG.md)
[![C++ Standard: C++17](https://img.shields.io/badge/C%2B%2B-17-blue)](https://en.cppreference.com/w/cpp/17)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-green)](https://www.kernel.org/)
[![Build: Make](https://img.shields.io/badge/Build-Make-orange)](Makefile)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

[English](README_en.md) &nbsp;.&nbsp; [Chinese](README.md) &nbsp;.&nbsp; [Japanese](README_ja.md) &nbsp;.&nbsp; [Russian](README_ru.md) &nbsp;.&nbsp; [Arabic](README_ar.md)

**高信頼性イベント駆動型分散タスクスケジューラー。**
epoll + timerfd + socketpair で構築、依存ライブラリゼロ。

</div>

---

## 目次

- [特徴](#特徴)
- [アーキテクチャ](#アーキテクチャ)
- [クイックスタート](#クイックスタート)
- [タスクタイプ](#タスクタイプ)
- [インタラクティブ制御](#インタラクティブ制御)
- [シグナル制御](#シグナル制御)
- [テストスイート](#テストスイート)
- [ビルドと実行](#ビルドと実行)
- [プロジェクト構成](#プロジェクト構成)
- [設計上の判断](#設計上の判断)
- [パフォーマンス](#パフォーマンス)
- [Roadmap](#roadmap)
- [ライセンス](#ライセンス)

---

## 特徴

| 特徴 | 実装方式 | メリット |
|------|----------|---------|
| **プロセス隔離** | fork() + socketpair | 単一Worker障害がシステム全体に影響しない |
| **O(1)I/O多重化** | epoll LTモード | 高負荷時も遅延を安定させる |
| **ナノ秒精度タイマー** | timerfd + itimerspec | 1sディスパッチ/5sレポート周期を正確に維持 |
| **ゼロコピーIPC** | socketpair SOCK_DGRAM | Manager-Worker間高效的通信 |
| **グレースフルシャットダウン** | SIGINT + 'X'メッセージ | ゾンビプロセスなし、タスクロスなし |
| **動的スケーリング** | 実行時 +/- または SIGUSR1/SIGUSR2 | リアルタイムにプールサイズ調整 |
| **障害自己修復** | ハートビート監視 | クラッシュWorkerを自動置換、保留タスクを救出 |
| **タイムアウトリトライ** | 5sタイムアウト/最大2回リトライ | ネットワーク揺れ時にタスクをロスしない |
| **構造化ログ** | タイムスタンプ付きJSONL | 事後分析対応 |

---

## アーキテクチャ

```
+-----------------------------------------------------------------------+
|                       Manager (parent process)                          |
|  +---------------------------------------------------------------+    |
|  |                     EventLoop (epoll)                           |    |
|  |   epoll_wait() ------------------------------------------->  |    |
|  |   +-----------+ +-----------+ +-----------+ +--------+        |    |
|  |   |timerfd    | |timerfd    | |timerfd    | | stdin  |        |    |
|  |   |1s dispatch| |2s heartbeat| |5s report  | |(+ / -) |        |    |
|  |   +-----+-----+ +-----+-----+ +-----+-----+ +---+----+        |    |
|  +--------+-----------+-----------+-----------+------+----+--------+    |
+----------+-----------+-----------+-----------+------+----+---------------+
            |           |           |           |      |
            V           V           V           V      V
      +---------+ +---------+ +---------+
      | Worker 1| | Worker 2| | Worker N |
      | (fork)  | | (fork)  | | (fork)  |
      |recv_task| |recv_task| |recv_task|
      | +-sleep | | +-sleep | | +-sleep |
      | +-done  | | +-done  | | +-done  |
      | +-pong  | | +-pong  | | +-pong  |
      +---------+ +---------+ +---------+
```

- **Manager**: 単一イベントループ、全FDライフサイクルを所有、ディスパッチ/ハートビート監視/レポートを担当。
- **Worker**: 純粋な実行ユニット——受信/処理/応答pong。スケジューリングロジックなし。
- **IPC**: Workerごとに1つのsocketpair、全二重、両端ノンブロッキング。

---

## クイックスタート

```bash
make                    # ビルド
./bin/scheduler --help  # ヘルプ表示
./bin/scheduler 5       # 5 Workerで起動（3 <= N <= 10）
make test               # 全テスト実行
make clean              # クリーンアップ
```

---

## タスクタイプ

| タイプ | 処理時間 | コックピットシナリオ |
|--------|---------|-------------------|
| **A** | 100 ms | センサーデータ取り込み |
| **B** | 200 ms | メディアストリーム処理 |
| **C** | 300 ms | ナビゲーション経路計算 |

---

## インタラクティブ制御

| 入力 | 操作 |
|------|------|
| `+` | Workerを1つ追加（上限10） |
| `-` | Workerを1つ削除（下限1） |
| `s`/`S` | 統計情報を即時表示 |
| `i`/`I` | Workerの詳細情報を表示 |
| `p`/`P` | 保留タスクトラッカーを表示 |
| `q`/`Q` | グレースフル終了 |
| `Ctrl+C` | グレースフルシャットダウン |

---

## シグナル制御

```bash
kill -SIGUSR1 $(pidof scheduler)   # Worker追加
kill -SIGUSR2 $(pidof scheduler)   # Worker削除
kill -SIGINT  $(pidof scheduler)   # グレースフル終了
```

---

## テストスイート

```bash
make test       # 全9テストスイート実行
make test-quick # スモークテストのみ
```

| テスト | 検証内容 |
|--------|---------|
| `test_boundary.sh` | N=3/10成功；N=2/11拒否 |
| `test_stress.sh` | Worker kill -9 -> 自己修復 |
| `test_dynamic.sh` | +/- 動的スケーリング |
| `test_signal.sh` | SIGUSR1/SIGUSR2 信号制御 |
| `test_timeout_retry.sh` | タイムアウト・リトライロジック |
| `test_perf.sh` | スループット・レイテンシ指標 |
| `test_concurrent.sh` | 並行正確性 |
| `test_graceful.sh` | Xプロトコル付きグレースフル終了 |
| `test_jsonl.sh` | 構造化JSONLログ |

---

## ビルドと実行

### 必要環境

| 依存 | バージョン |
|------|----------|
| Linuxカーネル | 4.x+ |
| GCC または Clang | 7+（C++17） |
| GNU Make | 任意の最近のバージョン |

### コマンド

```bash
make              # ビルド -> ./bin/scheduler
make test         # 全9テストスイート
make test-quick   # 境界テスト+グレースフル終了テストのみ
make install      # /usr/local/bin にインストール
make clean        # ./bin と *.jsonl を削除
make help         # ターゲット一覧表示
```

### 終了コード

| コード | 意味 |
|--------|------|
| `0` | 成功 |
| `64` | CLI使用エラー |
| `70` | ランタイムエラー（fork/socketpair/epoll_create失敗） |

---

## プロジェクト構成

```
VoYah_project/
|-- CMakeLists.txt              # CMake ビルド（オプション）
|-- Makefile                    # クイックビルドエントリ
|-- .editorconfig              # エディタ設定
|-- .gitignore                 # Git 除外ルール
|-- LICENSE                    # MITライセンス
|-- AUTHORS                    # 著者一覧
|-- CONTRIBUTING.md            # 寄稿ガイドライン
|-- CODE_OF_CONDUCT.md         # コミュニティ行動規範
|-- CHANGELOG.md              # バージョン履歴
|-- src/                       # ソースコード
|   |-- CMakeLists.txt
|   +-- scheduler.cpp           # 完全実装（約1000行）
|-- include/                   # 公開ヘッダー
|   +-- voyah/
|       +-- version.h          # バージョン定義
|-- docs/                      # ドキュメント
|   |-- README.md             # デフォルトエントリ（中国語）
|   |-- README_en.md          # 英語版
|   |-- README_ja.md          # このファイル（日本語）
|   |-- README_ru.md          # ロシア語版
|   |-- README_ar.md          # アラビア語版
|   +-- DESIGN.md              # システム設計書
|-- test/                      # 9つのテストスクリプト
|-- examples/                   # 使用例
|   +-- run_demo.sh           # デモ実行スクリプト
+-- .github/
    |-- workflows/ci.yml        # GitHub Actions CI/CD
    |-- ISSUE_TEMPLATE/          # Issue テンプレート
    +-- PULL_REQUEST_TEMPLATE.md # PR テンプレート
```

---

## 設計上の判断

### なぜ epoll か（select/poll ではなく）

| 基準 | select | poll | epoll |
|------|--------|------|-------|
| FD数上限 | FD_SETSIZE(1024) | 無制限 | 無制限 |
| 時間計算量 | O(n)全走査 | O(n)全走査 | **O(1)就緒FDのみ** |
| 呼び出し毎メモリ | 高（入出力2回コピー） | 高（入出力2回コピー） | 低（登録は1回） |
| コックピット適合性 | ×
|×
| **○ - リアルタイム/μs遅延** |

### なぜマルチプロセスか（マルチスレッドではなく）

- **信頼性**: 単一Worker障害は隔離され、Managerは継続動作。
- **ロック不要**: プロセス境界がデータ競合を本質的に排除。
- **モダンfork**: Copy-on-writeにより読み取り主体ワークロードでforkコストほぼゼロ。

### なぜ libevent / libuv ではなくネイティブsyscall

- Linux I/O基盤への深い理解を示す。
- ゼロ依存——Pure GNU/Linux。
- epoll + timerfd + socketpair で全I/O多重化・タイマー・IPC をカバー。

---

## パフォーマンス

| 指標 | 数値 |
|------|------|
| ディスパッチレイテンシ（1Worker、1タスク） | < 1 ms |
| epoll_wait返答時間 | < 100 us |
| タイマー精度（timerfd） | ナノ秒（itimerspec） |
| Worker fork+socketpair起動 | < 5 ms |
| グレースフル終了（N Worker） | < 100 ms + N x Worker処理時間 |
| 最大同時Worker数 | 10（設定可能） |

---

## Roadmap

- [ ] タスク重み・Worker負荷上限の設定対応
- [ ] 高優先度コックピットタスク向け優先キュー
- [ ] 共有メモリ（mmap）ゼロコピー転送
- [ ] HTTP/MQTT APIによるリモートタスク注入
- [ ] マルチManager HAモードとリーダー選挙
- [ ] リアルタイム可視化Webダッシュボード
- [ ] Windows WSL2互換レイヤー

---

## ライセンス

MIT License - [LICENSE](../LICENSE) 参照。
