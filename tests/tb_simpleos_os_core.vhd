-- SPDX-License-Identifier: MIT
-- End-to-end test of simpleos_os_core through its UART protocol. A PC-side
-- UART in the testbench loads image.hex with 'W', starts the CPU with 'X',
-- checks every SYSCALL against the golden checkpoints (number via 'S', all
-- registers via 'G'), exercises 'R' on string arguments, answers with 'C'
-- and finally compares the whole 1 MiB DDR3 model memory after 'H'.
-- The real timer cannot reproduce injected interrupts, so the golden file
-- must not request any (use the "os" mode of make_system_vectors.py).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;
entity tb_simpleos_os_core is
  generic (CLOCK_HZ : positive := 80000000; BAUD : positive := 4000000; TIMEOUT_MS : positive := 300);
end;
architecture test of tb_simpleos_os_core is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal fpga_rx, fpga_tx, pc_txd : std_logic := '1';
  signal line_break : std_logic := '0';
  signal leds : std_logic_vector(3 downto 0);
  signal calib, check, checked : std_logic := '0';
  signal app_addr : std_logic_vector(27 downto 0);
  signal app_cmd : std_logic_vector(2 downto 0);
  signal app_en,app_rdy,app_wdf_end,app_wdf_wren,app_wdf_rdy,app_rd_data_valid,app_rd_data_end : std_logic;
  signal app_wdf_data,app_rd_data : std_logic_vector(127 downto 0);
  signal app_wdf_mask : std_logic_vector(15 downto 0);
  -- PC side UART
  signal tx_valid : std_logic := '0';
  signal tx_ready, rx_valid, frame_error, overrun : std_logic;
  signal tx_data, rx_data : unsigned(7 downto 0) := (others=>'0');
begin
  clk<=not clk after 6.25 ns;
  core: entity work.simpleos_os_core
    generic map(CLOCK_HZ=>CLOCK_HZ, BAUD=>BAUD, TICK_CYCLES=>1000000000)
    port map(clk,reset,fpga_rx,fpga_tx,leds,app_addr,app_cmd,app_en,app_rdy,app_wdf_data,
      app_wdf_end,app_wdf_wren,app_wdf_mask,app_wdf_rdy,app_rd_data,app_rd_data_valid);
  model: entity work.migui_model
    generic map(IMAGE_FILE=>"", BASE_FILE=>"image.hex", FINAL_FILE=>"final-memory.hex")
    port map(clk,calib,app_addr,app_cmd,app_en,app_rdy,app_wdf_data,app_wdf_end,app_wdf_wren,
      app_wdf_mask,app_wdf_rdy,app_rd_data,app_rd_data_valid,app_rd_data_end,check,checked);
  reset<=not calib;
  fpga_rx<=pc_txd and not line_break;
  pc: entity work.simpleos_uart generic map(CLOCK_HZ,BAUD)
    port map(clk,'0',fpga_tx,pc_txd,tx_valid,tx_ready,tx_data,
             rx_valid,'1',rx_data,frame_error,overrun);

  process
    file image : text open read_mode is "image.hex";
    file golden : text open read_mode is "expected.hex";
    variable row : line;
    variable a20 : std_logic_vector(19 downto 0);
    variable b8 : std_logic_vector(7 downto 0);
    type run_type is array(0 to 255) of unsigned(7 downto 0);
    variable run : run_type;
    variable run_start, run_length, next_addr : natural := 0;
    variable sum : unsigned(7 downto 0);
    variable b : unsigned(7 downto 0);
    variable number : unsigned(15 downto 0);
    variable r8, r9, value : unsigned(31 downto 0);
    variable gnumber : std_logic_vector(19 downto 0);
    variable expected, result : std_logic_vector(31 downto 0);
    variable write_flag, irq_flag : std_logic_vector(3 downto 0);
    variable services, packets, bytes_loaded : natural := 0;

    procedure put(v : unsigned(7 downto 0)) is
    begin
      wait until falling_edge(clk) and tx_ready='1';
      tx_data<=v; tx_valid<='1';
      wait until falling_edge(clk); tx_valid<='0';
    end;
    procedure get(v : out unsigned(7 downto 0)) is
    begin
      loop wait until rising_edge(clk); exit when rx_valid='1'; end loop;
      v:=rx_data;
    end;
    procedure get32(v : out unsigned(31 downto 0)) is
      variable x : unsigned(31 downto 0) := (others=>'0');
      variable c : unsigned(7 downto 0);
    begin
      for i in 0 to 3 loop get(c); x:=x(23 downto 0) & c; end loop;
      v:=x;
    end;
    procedure put32(v : unsigned(31 downto 0)) is
    begin
      for i in 3 downto 0 loop put(v(8*i+7 downto 8*i)); end loop;
    end;
    -- (xelab 2022.1 crashes when a procedure here updates the process's
    -- array/counter variables, so the run is passed in and counted by the caller.)
    procedure send_w(start, len : natural; data : run_type) is
      variable s : unsigned(7 downto 0) := (others=>'0');
      variable reply : unsigned(7 downto 0);
      variable a24 : unsigned(23 downto 0);
      variable l16 : unsigned(15 downto 0);
    begin
      a24:=to_unsigned(start,24); l16:=to_unsigned(len,16);
      put(x"57"); put(a24(23 downto 16)); put(a24(15 downto 8)); put(a24(7 downto 0));
      put(l16(15 downto 8)); put(l16(7 downto 0));
      for i in 0 to len-1 loop put(data(i)); s:=s+data(i); end loop;
      put(s); get(reply);
      assert reply=x"4B" report "W rejected: " & to_hstring(reply) severity failure;
    end;
  begin
    get(b); assert b=x"42" report "expected B, got " & to_hstring(b) severity failure;
    -- Z must clear stale DDR3 contents: write garbage at both ends, zero, read back.
    run(0 to 1):=(x"A5",x"5A");
    send_w(0,2,run); send_w(16#FFFFE#,2,run);
    put(x"5A"); get(b); assert b=x"4B" report "Z not acknowledged" severity failure;
    for k in 0 to 1 loop
      put(x"52");
      if k=0 then put(x"00"); put(x"00"); put(x"00"); else put(x"0F"); put(x"FF"); put(x"FE"); end if;
      put(x"00"); put(x"02");
      get(b); assert b=0 report "Z left data" severity failure;
      get(b); assert b=0 report "Z left data" severity failure;
      get(b); assert b=0 report "R sum after Z" severity failure;
    end loop;
    -- Load the image in runs of consecutive non-zero bytes (memory starts zeroed).
    while not endfile(image) loop
      readline(image,row); hread(row,a20); hread(row,b8);
      if run_length>0 and (to_integer(unsigned(a20))/=next_addr or run_length=256) then
        send_w(run_start,run_length,run);
        packets:=packets+1; bytes_loaded:=bytes_loaded+run_length; run_length:=0;
      end if;
      if run_length=0 then run_start:=to_integer(unsigned(a20)); end if;
      run(run_length):=unsigned(b8); run_length:=run_length+1;
      next_addr:=to_integer(unsigned(a20))+1;
    end loop;
    if run_length>0 then
      send_w(run_start,run_length,run);
      packets:=packets+1; bytes_loaded:=bytes_loaded+run_length; run_length:=0;
    end if;
    report "loaded " & integer'image(bytes_loaded) & " bytes in " & integer'image(packets) & " W packets";
    -- Unknown command and C outside a SYSCALL must be rejected.
    put(x"3F"); get(b); assert b=x"45" report "unknown command not rejected" severity failure;
    put(x"43"); get(b); assert b=x"45" report "C accepted outside SYSCALL" severity failure;
    put(x"58");                                            -- X: start
    loop
      get(b);
      if b=x"53" then
        get(b); number(15 downto 8):=b; get(b); number(7 downto 0):=b;
        get32(r8); get32(r9);
        assert not endfile(golden) report "extra service" severity failure;
        readline(golden,row); hread(row,gnumber);
        assert number=unsigned(gnumber(15 downto 0)) report "service number mismatch" severity failure;
        put(x"47");                                        -- G: compare all registers
        for i in 0 to 15 loop
          hread(row,expected); get32(value);
          assert value=unsigned(expected)
            report "service " & integer'image(services) & " register " & integer'image(i)
              & " actual " & to_hstring(value) & " expected " & to_hstring(expected) severity failure;
          assert (i/=8 or r8=value) and (i/=9 or r9=value)
            report "S packet R8/R9 differ from G" severity failure;
        end loop;
        if number=1 or number=2 then                        -- R: read 8 bytes of the string
          put(x"52"); put(x"0" & r8(19 downto 16)); put(r8(15 downto 8)); put(r8(7 downto 0));
          put(x"00"); put(x"08"); sum:=(others=>'0');
          for i in 1 to 8 loop get(b); sum:=sum+b; end loop;
          get(b); assert b=sum report "R checksum mismatch" severity failure;
        end if;
        hread(row,write_flag); hread(row,result); hread(row,irq_flag);
        assert unsigned(irq_flag)=0 report "golden needs injected interrupts; use os mode" severity failure;
        put(x"43"); put("0000000" & write_flag(0)); put32(unsigned(result));
        services:=services+1;
      elsif b=x"48" then
        get(b); assert b=x"00" report "CPU fault stop" severity failure;
        assert endfile(golden) report "missing services" severity failure;
        put(x"47");                                        -- registers survive HALT
        for i in 0 to 15 loop
          get32(value);
          assert i/=12 or (value/=x"00080000" and value/=0) report "PC reset after HALT" severity failure;
        end loop;
        put(x"58"); get(b); assert b=x"45" report "X accepted after HALT" severity failure;
        put(x"5A"); get(b); assert b=x"45" report "Z accepted after HALT" severity failure;
        check<='1'; wait until checked='1';
        report "OS part passed: loaded " & integer'image(bytes_loaded) & " bytes, served "
          & integer'image(services) & " SYSCALLs with full register checks, full 1MiB final memory comparison";
        exit;
      else
        assert false report "unexpected packet " & to_hstring(b) severity failure;
      end if;
    end loop;
    -- BREAK returns to the loader.
    wait until falling_edge(clk); line_break<='1';
    wait for 25 * (1 sec / BAUD); line_break<='0';
    get(b); assert b=x"42" report "no B after BREAK" severity failure;
    -- SYSCALL 22 path: 0x80000: SYSCALL 22; HALT   0x00000: SYSCALL 20; RET
    run(0 to 7):=(x"60",x"00",x"00",x"16",x"01",x"00",x"00",x"00");
    send_w(16#80000#,8,run);
    put(x"58");
    get(b); assert b=x"53" report "no S for SYSCALL 22" severity failure;
    get(b); get(b); assert b=x"16" report "expected SYSCALL 22" severity failure;
    get32(r8); get32(r9);
    run(0 to 7):=(x"60",x"00",x"00",x"14",x"02",x"00",x"00",x"00");
    send_w(0,8,run);                                       -- W while in a SYSCALL
    put(x"43"); put(x"02"); put32(x"00000000");            -- C: push PC, jump to 0
    get(b); assert b=x"53" report "no S for SYSCALL 20" severity failure;
    get(b); get(b); assert b=x"14" report "expected SYSCALL 20 at address 0" severity failure;
    get32(r8); get32(r9);
    put(x"47");
    for i in 0 to 15 loop
      get32(value);
      assert i/=12 or value=x"00000004" report "PC after jump: " & to_hstring(value) severity failure;
      assert i/=11 or value=x"000FEFFC" report "SP after push: " & to_hstring(value) severity failure;
    end loop;
    put(x"52"); put(x"0F"); put(x"EF"); put(x"FC"); put(x"00"); put(x"04");
    get32(value); get(b);
    assert value=x"00080004" report "pushed PC: " & to_hstring(value) severity failure;
    assert b=x"0C" report "R checksum" severity failure;
    put(x"43"); put(x"00"); put32(x"00000000");
    get(b); assert b=x"48" report "no HALT after RET" severity failure;
    get(b); assert b=x"00" report "fault stop after RET" severity failure;
    report "PASS: UART monitor: OS image " & integer'image(bytes_loaded) & " bytes, "
      & integer'image(services) & " SYSCALLs, full 1MiB comparison; BREAK reset; SYSCALL 22 push/jump";
    finish;
  end process;
  process begin wait for TIMEOUT_MS * 1 ms;
    assert false report "core simulation timeout" severity failure;
  end process;
end;
