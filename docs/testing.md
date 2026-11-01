# 試験

シミュレーション試験はVivado Simulator 2022.1（xvhdl・xelab・xsim）を使う。Vivadoの場所は環境変数 `SIMPLEOS_VIVADO_BIN` で指定する（既定は `/home/itoh/Xilinx/Vivado/2022.1/bin`）。

期待値は、os_book_codeの固定版（`d377b03a8ca71f443474fa6c549fd710deaafedf`）の `emu.py` のCPU関数を、端末やプロセスを除いて直接実行して作る。試験はこのコミットであることを確かめてから始める。一部の試験はSimple-C（`a970ef6736a64916c8659be33403d76b1ba4ff6f`）も使う。

## まとめて実行する

```sh
bash tests/run_regression.sh <os_book_code> <Simple-C>
```

下の13本を順に実行し、それぞれのPASS行を表示する。1本でも失敗すれば終了コードが1になる。所要時間は数分。

## 試験の一覧

| 準備スクリプト | テストベンチ | 内容 |
|---|---|---|
| `prepare.sh` | `tb_simpleos_cpu.vhd` | 基本ISA。`base.asm` とSimple-Cのビット演算サンプルを実行し、SYSCALLの位置で全16レジスタを比較する（21か所）。メモリーは3クロックに1回だけ応答する |
| `prepare_system.sh MODE` | `tb_simpleos_system.vhd` | CPU＋MMU。全SYSCALLで全レジスタを比較し、終了時の主記憶1MiB全体を比較する |
| `prepare_ddr3_system.sh MODE` | `tb_simpleos_ddr3_system.vhd` | 上と同じ比較を、DDR3アダプターとMIG UIの振る舞いモデル経由で、81.25MHz相当のクロックで行う |
| `prepare_ddr3.sh` | `tb_simpleos_ddr3.vhd` | DDR3アダプター単体。少数のラインに集中させた乱数の読み書き2万回を参照と比較する |
| `prepare_os_core.sh` | `tb_simpleos_os_core.vhd` | コア全体をUARTプロトコル経由で試験する。`os.bin` を `W` でロードし、`X` で起動、全SYSCALLで `G` のレジスタを比較し、`R` も使う。続けて主記憶1MiB全体、BREAK、`Z`、SYSCALL 22の分岐を確かめる |
| `prepare_io.sh` | `tb_simpleos_io.vhd` | UART（エコー、偽スタート、フレーミング異常、受信あふれ）、LED、タイマーの保留とあふれ |
| — | `test_host.py` | PCホストをボードなしで試験する（下記） |

`MODE` は次の4つ。

| MODE | 内容 |
|---|---|
| `exceptions` | `tests/exceptions.asm`。タイマー割込み、データ・境界・命令フェッチでのページフォルト、IRET、ページ表の変更 |
| `os` | オリジナルのOSの起動から `exit` まで |
| `tasks` | オリジナルのOSで `taskexec pagefault.bin`。タスクの切替、タイマー割込み、ページ割当て、終了 |
| `c-tasks` | Simple-CのC版OSで同じ操作（第3引数にSimple-Cのディレクトリー） |

MODEの試験では、時刻と入力は固定し、割込みは `emu.py` で発生したのと同じ命令の位置で注入する。タスクのプログラムは、SYSCALL 23の時点で主記憶に置く。

準備スクリプトは一時ディレクトリーにシミュレーションを作り、実行する `xsim` コマンドを表示する。表示されたコマンドを別に実行し、PASS行とFailureやERRORがないことを確かめる。同じスクリプトの中でxelabの直後にxsimを起動すると、Tclの例外になる場合があるため、準備と実行を分けている（`run_regression.sh` は別のコマンドとして実行している）。

## PCホストの試験

```sh
python3 tests/test_host.py <os_book_code>
```

`emu.py` のCPUとMMUを、FPGAと同じUARTプロトコルの裏で動かす模擬FPGAを使う。主記憶は乱数で始め、SYSCALL 41以外を `S` でPCホストへ送る。本物の `simpleos_host.py` で、`ls`、`date`、`reg`、`taskexec pagefault.bin`、`exec hello.bin`・`mul.bin`・`dump.bin`、`exit` を入力し、表示とHALTを確かめる。

## 生成したMIGでの試験

```sh
bash tests/prepare_ddr3_mig.sh
```

DDR3アダプター単体の乱数試験を、生成したMIG（シミュレーション用の高速較正）とMicronのDDR3モデルで行う。先に `board/gen_mig.tcl` でMIGを生成しておく。約20分かかるので、回帰試験には含めず、DDR3アダプターやMIGの設定を変えたときに実行する。

DDR3モデルは較正中にライトレベリングやリセット時間の警告を出すが、較正後の読み書きでは警告は出ない。

## 振る舞いモデル

`tests/migui_model.vhd` はMIGネイティブUIの振る舞いモデル。較正の待ち、`app_rdy`・`app_wdf_rdy` の疑似乱数による停止、固定の読出し遅延、コマンド順の実行を再現する。実際のMIGとDDR3のタイミングは再現しないため、それは上の生成したMIGでの試験で確かめる。
