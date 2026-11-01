# その他の回路

DDR3でOSを動かす回路のほかに、次の2つの回路がある。どちらもOSは動かない。

## 単一プログラム用の回路

`rtl/simpleos_board.vhd` は、CPUと16KiBの内蔵RAMで、プログラムを1本だけ実行する。MMU、タイマー割込み、DDR3は使わない。

| 項目 | 内容 |
|---|---|
| クロック | R2の100MHz |
| メモリー | コード領域 0x80000〜0x81FFF（8KiB）、スタック領域 0xFE000〜0xFFFFF（8KiB）。領域外へのアクセスでは停止する。未書込みの部分は初期化しない |
| UART | Pmod JC（[ハードウェア](hardware.md)と同じ配線）、115200bps・8N1 |
| ビルド | `vivado -mode batch -source board/build_cpu.tcl -tclargs <出力先>` |
| 構成 | `board/program_cpu.tcl`（[ビルドと書込み](build.md#jtagで構成する)と同じ） |

### 転送の手順

1. リセット後またはBREAK後、FPGAが `B` を送る。
2. PCが `W`、長さ（2バイト、ビッグエンディアン、1〜8192）、データ、データの8bit加算の和を送る。データは0x80000から置かれる。正しく受けたら `K`、そうでなければ `E`。
3. PCが `R` を送ると実行を始める。
4. HALTでEOT（0x04）を送ってローダーへ戻る。対応しないSYSCALLや領域外アクセスでは、NAK（0x15）を送って停止する。

| SYSCALL | 動作 |
|---|---|
| 0 | R8の下位8bitをUARTへ出力 |
| 1 | R8が指すNUL終端の文字列をUARTへ出力 |
| 3 | UARTから1バイト受信してR8へ |
| 50 | R8の下位4bitでLD2〜LD5を点灯する（この回路だけの拡張） |

### ツール

| ツール | 内容 |
|---|---|
| `tools/assemble_sample.py` | os_book_codeの `asm.py` でサンプルをアセンブルする |
| `tools/build_c_sample.py` | Simple-Cで `samples/hello_c.c` をコンパイルする |
| `tools/build_upstream_samples.py` | os_book_codeの `test1.asm`・`test2.asm` を無改変で呼び出し、結果を表示する呼出し側を付ける |
| `tools/load_uart.py`、`tools/load_uart.ps1` | Linux・Windowsから転送して実行し、出力を表示する |
| `tools/make_ttl_loader.py` | Tera Termのマクロ（`.ttl`）と転送データ（`.uart`）を作る。Tera Termの「コントロール → マクロ」から実行すると、COMポートを切断せずにBREAK・転送・実行を行う |

`samples/` には、文字出力と乗除算とLED（`hello_led.asm`）、LEDの点滅（`blink.asm`）、繰り返し表示（`console_demo.asm`）、キー入力のエコー（`uart_input.asm`）、Simple-Cの例（`hello_c.c`）がある。

試験は `tests/prepare_board.sh`（UARTのワイヤー動作、転送の拒否、和の検査、文字出力、乗除算、LED、HALT）。

## 接続確認用の回路

`rtl/simpleos_io_demo.vhd` は、CPUを含まないLEDとUARTの確認用の回路。

| 項目 | 内容 |
|---|---|
| UART | Arty内蔵のUSB-UART、115200bps・8N1。受けたバイトをそのまま返す |
| LD2 | 1秒周期で点滅 |
| LD3 | エコーを送るたびに反転 |
| LD4 | 受信のフレーミング異常（リセットまで保持） |
| LD5 | 受信あふれ（リセットまで保持） |
| リセット | BTN0 |
| ビルド | `vivado -mode batch -source board/build_io.tcl -tclargs <出力先>` |

試験は `tests/prepare_io.sh`。
