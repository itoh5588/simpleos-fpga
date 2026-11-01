# ハードウェア

## 必要なもの

- Digilent Arty S7-50
- 3.3V TTLのUSB-UARTアダプター（FTDI FT232Rなど、3Mbaudに対応するもの）
- ビルド用：Vivado 2022.1（MIG 4.2を使う）
- PCホスト用：Python 3とpyserial（Windows・Linuxのどちらでもよい）
- os_book_code（`d377b03a8ca71f443474fa6c549fd710deaafedf`）

## 配線

UARTはArty内蔵のUSB-UARTではなく、Pmod JCにつないだ外付けアダプターを使う。

| 信号 | Arty S7 | FPGAピン |
|---|---|---|
| FPGA送信 → アダプター受信 | Pmod JC1 | U15 |
| FPGA受信 ← アダプター送信 | Pmod JC2 | V16 |
| GND | Pmod JC5 | — |

FPGAの受信ピンはプルアップしてある。通信は3Mbaud・8N1・フロー制御なし。

ArtyのUSB（内蔵のFT2232）は、JTAGでの書込みと電源に使う。

## USB-UARTアダプターの設定

FTDIのドライバーは、少量の受信データを「待ち時間タイマー」（既定16ms）の間ためてからPCへ渡す。OSはSYSCALLのたびにFPGAとPCの間で短い往復をするため、16msのままでは操作が大幅に遅くなる。1msにする。

- Windows：デバイスマネージャー → ポート（COMとLPT）→ アダプターのCOMポートのプロパティ → ポートの設定 → 詳細設定 → 待ち時間タイマー（msec）を1にする。詳細設定とプロパティの両方でOKを押し、アダプターを挿し直すと反映される。値はレジストリ `HKLM\SYSTEM\CurrentControlSet\Enum\FTDIBUS\VID_0403+PID_6001+<シリアル>\0000\Device Parameters` の `LatencyTimer` で確認できる。
- Linux：`/sys/bus/usb-serial/devices/ttyUSB*/latency_timer` に1を書く。

3Mbaud・1msでの往復時間は、1バイトの読出しで約1ms、256バイトの読み書きで約2ms。

この設定はアダプターごとに保存され、ほかのアプリケーションの通信速度には影響しない。

## 電源投入時の起動

SPIフラッシュに書き込んだ回路から起動するには、MODEジャンパー（JP1）を付ける。書込み方法は [ビルドと書込み](build.md)。

## クロック

基板の12MHz発振器（F14）を使う。100MHz発振器（R2）は使わない。R2はDDR3のバンクにあり、同じクロック領域のMMCMをMIGが使うため、自前のMMCMへ専用経路でつなげない。詳しくは [回路の構成](architecture.md)。

## LED

基板に印刷された番号で示す。LD0・LD1（3色LED）は使わない。

| LED | FPGAピン | 表示 |
|---|---|---|
| LD2 | E18 | DDR3の較正が終わり、回路が動作中 |
| LD3 | F13 | CPUが実行中 |
| LD4 | E13 | SYSCALLの処理中。入力待ちのOSはキー入力を問い合わせ続けるため、ほぼ点灯して見える |
| LD5 | H15 | フォルト停止、UART受信の異常（フレーミング・あふれ）、タイマーの保留あふれ |

BTN0（G15）はMIGごと回路全体をリセットする。
