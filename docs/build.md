# ビルドと書込み

コマンドはリポジトリのルートで実行する。生成物は `build/` に置かれる（gitの管理外）。

## MIGの生成

```sh
vivado -mode batch -source board/gen_mig.tcl
```

`board/mig_artys7.prj` からMIG 4.2のIPを `build/mig/` に生成する。最初に1回だけ実行する。設定の内容は [回路の構成](architecture.md#migの設定)。生成されるMIGとMicronのDDR3モデルはAMD（Xilinx）のライセンスなので、リポジトリには含めない。

## bitstreamのビルド

```sh
vivado -mode batch -source board/build_os.tcl -tclargs build/os [BAUD]
```

- `build/os/simpleos_os_board.bit` を作る。所要時間は約5分。
- `BAUD` はUARTの通信速度で、既定は3000000。変えた場合は、PCホストの `--baud` も同じ値にする。
- 配置配線の後にタイミング違反があれば、物理最適化と再配線を自動で行う。それでもsetupかholdの違反が残れば、bitstreamを出さずに止まる。
- `build/os/` に使用量（`utilization.rpt`）、タイミング（`timing.rpt`）、クロック（`clocks.rpt`）、DRC（`drc.rpt`）のレポートを残す。

## JTAGで書き込む

```sh
vivado -mode batch -source board/program_cpu.tcl -tclargs build/os/simpleos_os_board.bit BOARD_SERIAL
```

- `BOARD_SERIAL` は、VivadoのHardware Managerに表示されるDigilentの基板シリアル番号。複数の基板がつながっていても、書込み先を取り違えないために指定する。
- 電源を切ると消える。
- WSLでは、ArtyのUSB（FT2232、0403:6010）を `usbipd attach --wsl --busid <BUSID>` でWSLへ接続しておく。COM5などのUSB-UARTアダプターは、PCホストを動かす側（Windows）に残す。
- GUIのHardware Managerが接続中だと失敗するので、閉じておく。

## SPIフラッシュに書き込む

電源投入時に自動で起動させるには、SPIフラッシュ（Micron MT25QL128、16MiB）に書く。起動にはMODEジャンパー（JP1）が必要。

```sh
vivado -mode batch -source board/readback_flash.tcl -tclargs flash-backup.bin BOARD_SERIAL
vivado -mode batch -source board/flash.tcl -tclargs build/os/simpleos_os_board.bit BOARD_SERIAL
```

- `readback_flash.tcl` はフラッシュ全体（16MiB）をファイルに読み出す。フラッシュの内容は変えない。所要時間は約1分。上書きする前に必ず保存しておく。
- `flash.tcl` は `.mcs`（SPI x1）を作り、消去・書込み・照合を行った後、FPGAをフラッシュから再起動してDONEを確認する。所要時間は約1分。
- どちらも、FPGAをVivadoのフラッシュ書込み用回路で構成し直すため、JTAGで書いていた回路は消える。
- 保存したファイルや別の回路の `.bit` を `flash.tcl` で書けば、元に戻せる。
