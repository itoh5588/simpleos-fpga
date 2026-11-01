-- SPDX-License-Identifier: MIT
-- DDR3 byte adapter against the generated MIG (fast simulation calibration)
-- and the Micron DDR3 model that MIG ships with its example design.
-- Same clustered random traffic as tb_simpleos_ddr3, checked against a
-- reference array; also reports the ui_clk cycles spent per access.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_simpleos_ddr3_mig is
  generic (OPERATIONS : positive := 4000);
end;
architecture test of tb_simpleos_ddr3_mig is
  component ddr3_model
    port (
      rst_n, ck, ck_n, cke, cs_n, ras_n, cas_n, we_n : in std_logic;
      dm_tdqs : inout std_logic_vector(1 downto 0);
      ba : in std_logic_vector(2 downto 0);
      addr : in std_logic_vector(13 downto 0);
      dq : inout std_logic_vector(15 downto 0);
      dqs, dqs_n : inout std_logic_vector(1 downto 0);
      tdqs_n : out std_logic_vector(1 downto 0);
      odt : in std_logic);
  end component;
  signal sys_clk, clk_ref : std_logic := '0';
  signal sys_rst_n : std_logic := '0';
  signal clk, reset, calib : std_logic;
  signal valid, write, ready : std_logic := '0';
  signal addr : unsigned(19 downto 0) := (others=>'0');
  signal wdata, rdata : unsigned(7 downto 0) := (others=>'0');
  signal app_addr : std_logic_vector(27 downto 0);
  signal app_cmd : std_logic_vector(2 downto 0);
  signal app_en,app_rdy,app_wdf_end,app_wdf_wren,app_wdf_rdy,app_rd_data_valid,app_rd_data_end : std_logic;
  signal app_wdf_data,app_rd_data : std_logic_vector(127 downto 0);
  signal app_wdf_mask : std_logic_vector(15 downto 0);
  signal sr_active, ref_ack, zq_ack : std_logic;
  signal ddr3_dq : std_logic_vector(15 downto 0);
  signal ddr3_dqs_p, ddr3_dqs_n, ddr3_dm : std_logic_vector(1 downto 0);
  signal ddr3_addr : std_logic_vector(13 downto 0);
  signal ddr3_ba : std_logic_vector(2 downto 0);
  signal ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n : std_logic;
  signal ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n, ddr3_odt : std_logic_vector(0 downto 0);
begin
  sys_clk<=not sys_clk after 5 ns;      -- 100 MHz
  clk_ref<=not clk_ref after 2.5 ns;    -- 200 MHz IDELAYCTRL reference
  sys_rst_n<='1' after 200 ns;

  mig: entity work.simpleos_mig port map(
    ddr3_dq=>ddr3_dq, ddr3_dqs_p=>ddr3_dqs_p, ddr3_dqs_n=>ddr3_dqs_n,
    ddr3_addr=>ddr3_addr, ddr3_ba=>ddr3_ba, ddr3_ras_n=>ddr3_ras_n, ddr3_cas_n=>ddr3_cas_n,
    ddr3_we_n=>ddr3_we_n, ddr3_reset_n=>ddr3_reset_n, ddr3_ck_p=>ddr3_ck_p, ddr3_ck_n=>ddr3_ck_n,
    ddr3_cke=>ddr3_cke, ddr3_cs_n=>ddr3_cs_n, ddr3_dm=>ddr3_dm, ddr3_odt=>ddr3_odt,
    app_addr=>app_addr, app_cmd=>app_cmd, app_en=>app_en, app_wdf_data=>app_wdf_data,
    app_wdf_end=>app_wdf_end, app_wdf_mask=>app_wdf_mask, app_wdf_wren=>app_wdf_wren,
    app_rd_data=>app_rd_data, app_rd_data_end=>app_rd_data_end, app_rd_data_valid=>app_rd_data_valid,
    app_rdy=>app_rdy, app_wdf_rdy=>app_wdf_rdy, app_sr_req=>'0', app_ref_req=>'0', app_zq_req=>'0',
    app_sr_active=>sr_active, app_ref_ack=>ref_ack, app_zq_ack=>zq_ack,
    ui_clk=>clk, ui_clk_sync_rst=>reset, init_calib_complete=>calib,
    sys_clk_i=>sys_clk, clk_ref_i=>clk_ref, sys_rst=>sys_rst_n);

  mem: ddr3_model port map(
    rst_n=>ddr3_reset_n, ck=>ddr3_ck_p(0), ck_n=>ddr3_ck_n(0), cke=>ddr3_cke(0), cs_n=>ddr3_cs_n(0),
    ras_n=>ddr3_ras_n, cas_n=>ddr3_cas_n, we_n=>ddr3_we_n, dm_tdqs=>ddr3_dm, ba=>ddr3_ba,
    addr=>ddr3_addr, dq=>ddr3_dq, dqs=>ddr3_dqs_p, dqs_n=>ddr3_dqs_n, tdqs_n=>open, odt=>ddr3_odt(0));

  dut: entity work.simpleos_ddr3 port map(clk,reset,valid,write,addr,wdata,ready,rdata,
    app_addr,app_cmd,app_en,app_rdy,app_wdf_data,app_wdf_end,app_wdf_wren,app_wdf_mask,
    app_wdf_rdy,app_rd_data,app_rd_data_valid);

  process
    type ref_type is array(0 to 1048575) of unsigned(7 downto 0);
    variable ref : ref_type := (others=>(others=>'0'));
    variable known : bit_vector(0 to 1048575) := (others=>'0');
    variable lfsr : unsigned(31 downto 0) := x"1234ABCD";
    variable a : unsigned(19 downto 0);
    variable reads, writes, checked, wait_cycles, read_cycles, max_read : natural := 0;
    variable t0 : time;
    procedure step is
    begin
      lfsr:=lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
    end;
  begin
    wait until calib='1';
    report "MIG calibration complete at " & time'image(now);
    wait until rising_edge(clk) and reset='0';
    t0:=now;
    for n in 1 to OPERATIONS loop
      step; step; step; step; step; step; step; step;
      if lfsr(7 downto 5)="000" then a:=lfsr(19 downto 0);
      else
        case to_integer(lfsr(9 downto 8)) is
          when 0 => a:=x"00000"; when 1 => a:=x"00010";
          when 2 => a:=x"FEFF0"; when others => a:=x"FFFF0";
        end case;
        a(3 downto 0):=lfsr(13 downto 10);
      end if;
      wait until falling_edge(clk);
      valid<='1'; addr<=a; write<=lfsr(14); wdata<=lfsr(23 downto 16);
      wait_cycles:=0;
      loop wait until rising_edge(clk); wait_cycles:=wait_cycles+1; exit when ready='1'; end loop;
      if write='1' then
        ref(to_integer(a)):=wdata; known(to_integer(a)):='1'; writes:=writes+1;
      else
        -- DDR3 contents are undefined until written; check only known bytes.
        if known(to_integer(a))='1' then
          assert rdata=ref(to_integer(a))
            report "read mismatch at " & to_hstring(a) & " got " & to_hstring(rdata)
              & " expected " & to_hstring(ref(to_integer(a))) severity failure;
          checked:=checked+1;
        end if;
        reads:=reads+1; read_cycles:=read_cycles+wait_cycles;
        if wait_cycles>max_read then max_read:=wait_cycles; end if;
      end if;
      if lfsr(15)='1' then valid<='0'; wait until falling_edge(clk); end if;
      valid<='0';
    end loop;
    report "PASS: DDR3 adapter with MIG+DDR3 model, " & integer'image(reads) & " reads ("
      & integer'image(checked) & " checked), " & integer'image(writes) & " writes; average read "
      & integer'image(read_cycles/reads) & " cycles, max " & integer'image(max_read)
      & "; traffic time " & time'image(now-t0);
    finish;
  end process;

  process begin wait for 20 ms;
    assert false report "MIG simulation timeout" severity failure;
  end process;
end;
