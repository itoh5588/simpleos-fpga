# Simple OS FPGA

書籍『いちばんやさしい！OS自作超入門』（末安泰三著、日経BP）のSimple OS（[os_book_code](https://github.com/sueyasu/os_book_code)）を、FPGA上の独自CPUで実行する。対象基板はDigilent Arty S7-50。オリジナルの `os.asm` を無改変でアセンブルした `os.bin` を、DDR3に置いた1MiBの主記憶で動かす。

CPU・MMU・タイマー・DDR3アダプターはVHDLで実装し、SYSCALLはUARTでつないだPCホストが処理する。PCホストは書籍の `emu.py` の表示関数をそのまま使うため、画面表示はエミュレーターと同じになる。

## すぐに動かす

1. Arty S7-50のPmod JCにUSB-UARTアダプターをつなぐ（[ハードウェア](docs/hardware.md)）。
2. bitstreamを作り、FPGAに書き込む（[ビルドと書込み](docs/build.md)）。

   ```sh
   vivado -mode batch -source board/gen_mig.tcl
   vivado -mode batch -source board/build_os.tcl -tclargs build/os
   vivado -mode batch -source board/program_cpu.tcl -tclargs build/os/simpleos_os_board.bit BOARD_SERIAL
   ```

3. PCホストを起動する（[PCホスト](docs/host.md)）。

   ```powershell
   py tools\simpleos_host.py COM5 --book <os_book_codeのパス>
   ```

## ドキュメント

| 章 | 内容 |
|---|---|
| [ハードウェア](docs/hardware.md) | 必要なもの、配線、USB-UARTの設定、LED |
| [回路の構成](docs/architecture.md) | クロック、CPU・MMU・タイマー、DDR3アダプター、MIGの設定 |
| [UARTプロトコルとSYSCALL](docs/protocol.md) | FPGAとPCのやり取り、SYSCALLごとの処理 |
| [ビルドと書込み](docs/build.md) | MIGの生成、bitstreamのビルド、JTAG・SPIフラッシュへの書込み |
| [PCホスト](docs/host.md) | 使い方、内部の動作、実機の自動確認 |
| [試験](docs/testing.md) | シミュレーション試験の種類と実行方法 |
| [ISAの互換仕様](docs/isa.md) | `emu.py` と一致させているCPUの仕様 |
| [その他の回路](docs/other-designs.md) | OSを使わない単一プログラム用の回路、接続確認用の回路 |

## ライセンス

MIT（[LICENSE](LICENSE)）。`board/mig_artys7.prj` はDigilentのボードファイル（MIT）を元にしている。Vivadoが生成するMIGとDDR3モデルはリポジトリに含めない。
