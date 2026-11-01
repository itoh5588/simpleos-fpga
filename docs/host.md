# PCホスト

`tools/simpleos_host.py` は、FPGAで動くSimple OSの端末とSYSCALLの処理を受け持つ。Windows・Linuxのどちらでも動く。pyserialが必要。

## 使い方

```powershell
py tools\simpleos_host.py COM5 --book <os_book_codeのパス>
```

| 引数 | 内容 |
|---|---|
| `COM5` | USB-UARTアダプターのポート（Linuxでは `/dev/ttyUSB0` など） |
| `--book` | os_book_codeのディレクトリー。`emu.py`・`os.bin`・`dir/` を使う |
| `--os-bin` | OSイメージを個別に指定する（既定は `BOOK/os.bin`） |
| `--dir` | プログラム用ディレクトリーを個別に指定する（既定は `BOOK/dir`）。`ls`・`exec`・`taskexec` が使う |
| `--baud` | 通信速度。bitstreamと同じにする（既定3000000） |

`os.bin` はos_book_codeで `python asm.py os.asm` を実行して作る。`exec` や `taskexec` で使うプログラムも、同じアセンブラーで `.bin` にして `--dir` に置く。

同じCOMポートを使う端末ソフト（Tera Termなど）は、切断してから起動する。

## キー操作

| キー | 動作 |
|---|---|
| 通常のキー | 表示中の仮想コンソールの入力としてOSへ渡す。Enterは `emu.py` に合わせてLF（10）として渡す |
| Ctrl+] に続けて 0〜3 | 仮想コンソールを切り替える（`emu.py` と同じ） |
| Ctrl+] に続けて q | ホストを終了する。FPGAはそのまま残り、次の起動時にBREAKでリセットする |

HALTやフォルト停止の後は「Press any key to close.」と表示し、キーを押すまで終了しない。Windowsで新しいウィンドウから起動した場合に、停止時の表示を読めるようにするため。

## 内部の動作

- 起動時に、os_book_codeの `emu.py` から次の関数をそのまま読み込む：`vc_write`、`switch_vc`、`_tty_show_vc`、`_task_to_vc`、`_vc_trunc`、`print_registers`、`hexdump`、`_read_c_string`、`get_paddr`、`read_lmem`、`PageFault`。関数の定義だけを実行し、`emu.py` の端末設定やプロセスの起動は実行しない。
- これらの関数が使う `memory` を、FPGAの物理メモリーを `R`・`W` で読み書きするオブジェクトに置き換える。表示の書式、仮想コンソール、文字列の7bit化とバックスラッシュ列の解釈は `emu.py` と同じになる。
- SYSCALLの処理は `emu.py` の `do_syscall` と同じ順で分岐する。番号ごとの処理は [UARTプロトコルとSYSCALL](protocol.md#syscallの処理)。
- タスクnの出力は仮想コンソールnに入り、表示中でない仮想コンソールの出力は画面に出ない（`emu.py` と同じ）。
- `emu.py` は端末制御に `termios` と `fork` を使うためWindowsでは動かないが、PCホストはキー入力を自前で読むので（Windowsは `msvcrt`、Linuxは `termios`）、どちらでも動く。WindowsではANSIのエスケープシーケンスを有効にする。

## 実機の自動確認

```powershell
py tools\check_board.py COM5 --book <os_book_codeのパス> --dir <プログラム用ディレクトリー>
```

`tools/check_board.py` は、PCホストと同じ処理を使って、実機を自動で確認する。

1. BREAKと `Z` の後、16KiBの乱数を4か所（0x00000、0x40000、0x80000、0xFC000）に書いて読み戻し、一致を確かめる。`Z` で0にした領域と、リセット直後のレジスタも確かめる。
2. OSを起動し、`ls`、`date`、`reg`、`taskexec pagefault.bin`、`exec hello.bin`、`exec mul.bin`、`exec dump.bin`、`exit` を順に入力して、それぞれの表示を確かめる。

`--dir` には、os_book_codeの `pagefault.asm`・`hello.asm`・`mul.asm`・`dump.asm` をアセンブルした `.bin` を置く。3Mbaudでは全体で数秒で終わる。
