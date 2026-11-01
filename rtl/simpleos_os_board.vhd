-- SPDX-License-Identifier: MIT
-- Arty S7-50 top level for running Simple OS from DDR3.
-- F14 12 MHz -> MMCM (VCO 600 MHz) -> 100 MHz MIG system clock + 200 MHz
-- reference clock, as in Digilent's Arty S7 MIG designs. The 100 MHz R2
-- oscillator is not used: its clock region's MMCM belongs to the MIG.
-- The OS core runs on the MIG ui_clk (DDR3 325 MHz / 4 = 81.25 MHz) and is
-- held in reset until calibration completes. BTN0 resets the MIG.
-- UART: Pmod JC1 (FPGA TX) / JC2 (FPGA RX), 115200 8N1, see simpleos_os_core.
-- LED0 core alive (calibrated), LED1 CPU running, LED2 in SYSCALL, LED3 error.
library ieee;
use ieee.std_logic_1164.all;
library unisim;
use unisim.vcomponents.all;

entity simpleos_os_board is
  generic (BAUD : positive := 115200);
  port (
    I_CLK12, I_RESET, I_RXD : in std_logic;
    O_TXD : out std_logic;
    O_LED : out std_logic_vector(3 downto 0);
    ddr3_dq : inout std_logic_vector(15 downto 0);
    ddr3_dqs_p, ddr3_dqs_n : inout std_logic_vector(1 downto 0);
    ddr3_addr : out std_logic_vector(13 downto 0);
    ddr3_ba : out std_logic_vector(2 downto 0);
    ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n : out std_logic;
    ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n, ddr3_odt : out std_logic_vector(0 downto 0);
    ddr3_dm : out std_logic_vector(1 downto 0)
  );
end;

architecture rtl of simpleos_os_board is
  component simpleos_mig
    port (
      ddr3_dq : inout std_logic_vector(15 downto 0);
      ddr3_dqs_p, ddr3_dqs_n : inout std_logic_vector(1 downto 0);
      ddr3_addr : out std_logic_vector(13 downto 0);
      ddr3_ba : out std_logic_vector(2 downto 0);
      ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n : out std_logic;
      ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n : out std_logic_vector(0 downto 0);
      ddr3_dm : out std_logic_vector(1 downto 0);
      ddr3_odt : out std_logic_vector(0 downto 0);
      app_addr : in std_logic_vector(27 downto 0);
      app_cmd : in std_logic_vector(2 downto 0);
      app_en : in std_logic;
      app_wdf_data : in std_logic_vector(127 downto 0);
      app_wdf_end : in std_logic;
      app_wdf_mask : in std_logic_vector(15 downto 0);
      app_wdf_wren : in std_logic;
      app_rd_data : out std_logic_vector(127 downto 0);
      app_rd_data_end, app_rd_data_valid, app_rdy, app_wdf_rdy : out std_logic;
      app_sr_req, app_ref_req, app_zq_req : in std_logic;
      app_sr_active, app_ref_ack, app_zq_ack : out std_logic;
      ui_clk, ui_clk_sync_rst, init_calib_complete : out std_logic;
      sys_clk_i, clk_ref_i, sys_rst : in std_logic
    );
  end component;
  signal clk_fb, clk100_mmcm, clk200_mmcm, clk100, clk200, locked : std_logic;
  signal sys_rst_n : std_logic;
  signal ui_clk, ui_rst, calib, core_reset : std_logic;
  signal app_addr : std_logic_vector(27 downto 0);
  signal app_cmd : std_logic_vector(2 downto 0);
  signal app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy : std_logic;
  signal app_rd_data_valid, app_rd_data_end : std_logic;
  signal app_wdf_data, app_rd_data : std_logic_vector(127 downto 0);
  signal app_wdf_mask : std_logic_vector(15 downto 0);
  signal sr_active, ref_ack, zq_ack : std_logic;
begin
  clocks: MMCME2_BASE
    generic map (CLKIN1_PERIOD=>83.333, DIVCLK_DIVIDE=>1, CLKFBOUT_MULT_F=>50.0,
                 CLKOUT0_DIVIDE_F=>6.0, CLKOUT1_DIVIDE=>3)
    port map (CLKIN1=>I_CLK12, CLKFBIN=>clk_fb, CLKFBOUT=>clk_fb,
              CLKOUT0=>clk100_mmcm, CLKOUT1=>clk200_mmcm, LOCKED=>locked,
              RST=>'0', PWRDWN=>'0',
              CLKFBOUTB=>open, CLKOUT0B=>open, CLKOUT1B=>open, CLKOUT2=>open, CLKOUT2B=>open,
              CLKOUT3=>open, CLKOUT3B=>open, CLKOUT4=>open, CLKOUT5=>open, CLKOUT6=>open);
  buf100: BUFG port map (I=>clk100_mmcm, O=>clk100);
  buf200: BUFG port map (I=>clk200_mmcm, O=>clk200);
  sys_rst_n<=locked and not I_RESET;

  mig: simpleos_mig port map (
    ddr3_dq=>ddr3_dq, ddr3_dqs_p=>ddr3_dqs_p, ddr3_dqs_n=>ddr3_dqs_n,
    ddr3_addr=>ddr3_addr, ddr3_ba=>ddr3_ba, ddr3_ras_n=>ddr3_ras_n, ddr3_cas_n=>ddr3_cas_n,
    ddr3_we_n=>ddr3_we_n, ddr3_reset_n=>ddr3_reset_n, ddr3_ck_p=>ddr3_ck_p, ddr3_ck_n=>ddr3_ck_n,
    ddr3_cke=>ddr3_cke, ddr3_cs_n=>ddr3_cs_n, ddr3_dm=>ddr3_dm, ddr3_odt=>ddr3_odt,
    app_addr=>app_addr, app_cmd=>app_cmd, app_en=>app_en, app_wdf_data=>app_wdf_data,
    app_wdf_end=>app_wdf_end, app_wdf_mask=>app_wdf_mask, app_wdf_wren=>app_wdf_wren,
    app_rd_data=>app_rd_data, app_rd_data_end=>app_rd_data_end, app_rd_data_valid=>app_rd_data_valid,
    app_rdy=>app_rdy, app_wdf_rdy=>app_wdf_rdy, app_sr_req=>'0', app_ref_req=>'0', app_zq_req=>'0',
    app_sr_active=>sr_active, app_ref_ack=>ref_ack, app_zq_ack=>zq_ack,
    ui_clk=>ui_clk, ui_clk_sync_rst=>ui_rst, init_calib_complete=>calib,
    sys_clk_i=>clk100, clk_ref_i=>clk200, sys_rst=>sys_rst_n);

  core_reset<=ui_rst or not calib;
  core: entity work.simpleos_os_core
    generic map (CLOCK_HZ=>81250000, BAUD=>BAUD, TICK_CYCLES=>8125000)
    port map (clk=>ui_clk, reset=>core_reset, rxd=>I_RXD, txd=>O_TXD, leds=>O_LED,
      app_addr=>app_addr, app_cmd=>app_cmd, app_en=>app_en, app_rdy=>app_rdy,
      app_wdf_data=>app_wdf_data, app_wdf_end=>app_wdf_end, app_wdf_wren=>app_wdf_wren,
      app_wdf_mask=>app_wdf_mask, app_wdf_rdy=>app_wdf_rdy,
      app_rd_data=>app_rd_data, app_rd_data_valid=>app_rd_data_valid);
end;
