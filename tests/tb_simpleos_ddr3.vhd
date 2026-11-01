-- SPDX-License-Identifier: MIT
-- Directed random test of the DDR3 byte adapter against a reference array.
-- Accesses cluster on a few 16-byte lines so that writes into the buffered
-- line, line reuse and line replacement all occur often.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_simpleos_ddr3 is
  generic (OPERATIONS : positive := 20000);
end;
architecture test of tb_simpleos_ddr3 is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal valid, write, ready, calib, done : std_logic := '0';
  signal addr : unsigned(19 downto 0) := (others=>'0');
  signal wdata, rdata : unsigned(7 downto 0) := (others=>'0');
  signal app_addr : std_logic_vector(27 downto 0);
  signal app_cmd : std_logic_vector(2 downto 0);
  signal app_en,app_rdy,app_wdf_end,app_wdf_wren,app_wdf_rdy,app_rd_data_valid,app_rd_data_end : std_logic;
  signal app_wdf_data,app_rd_data : std_logic_vector(127 downto 0);
  signal app_wdf_mask : std_logic_vector(15 downto 0);
begin
  clk<=not clk after 6.25 ns;
  dut: entity work.simpleos_ddr3 port map(clk,reset,valid,write,addr,wdata,ready,rdata,
    app_addr,app_cmd,app_en,app_rdy,app_wdf_data,app_wdf_end,app_wdf_wren,app_wdf_mask,
    app_wdf_rdy,app_rd_data,app_rd_data_valid);
  model: entity work.migui_model generic map(IMAGE_FILE=>"",CALIB_CYCLES=>20)
    port map(clk,calib,app_addr,app_cmd,app_en,app_rdy,app_wdf_data,app_wdf_end,app_wdf_wren,
      app_wdf_mask,app_wdf_rdy,app_rd_data,app_rd_data_valid,app_rd_data_end,'0',done);
  process
    type ref_type is array(0 to 1048575) of unsigned(7 downto 0);
    variable ref : ref_type := (others=>(others=>'0'));
    variable lfsr : unsigned(31 downto 0) := x"1234ABCD";
    variable a : unsigned(19 downto 0);
    variable reads, writes : natural := 0;
    procedure step is
    begin
      lfsr:=lfsr(30 downto 0) & (lfsr(31) xor lfsr(21) xor lfsr(1) xor lfsr(0));
    end;
  begin
    wait until calib='1'; wait until falling_edge(clk); reset<='0';
    for n in 1 to OPERATIONS loop
      step; step; step; step; step; step; step; step;
      -- Mostly 4 lines at 0x00000/0x00010/0xFEFF0/0xFFFF0, sometimes anywhere.
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
      loop wait until rising_edge(clk); exit when ready='1'; end loop;
      if write='1' then
        ref(to_integer(a)):=wdata; writes:=writes+1;
      else
        assert rdata=ref(to_integer(a))
          report "read mismatch at " & to_hstring(a) & " got " & to_hstring(rdata)
            & " expected " & to_hstring(ref(to_integer(a))) severity failure;
        reads:=reads+1;
      end if;
      -- Hold idle for 0 or 1 cycle to vary request spacing.
      if lfsr(15)='1' then valid<='0'; wait until falling_edge(clk); end if;
      valid<='0';
    end loop;
    report "PASS: DDR3 adapter " & integer'image(reads) & " reads, "
      & integer'image(writes) & " writes matched the reference";
    finish;
  end process;
end;
