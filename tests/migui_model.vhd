-- SPDX-License-Identifier: MIT
-- Behavioral model of a 7-series MIG native UI (x16 DDR3, 4:1, 128-bit),
-- STRICT ordering. Not cycle accurate: it injects pseudo-random app_rdy /
-- app_wdf_rdy stalls, a calibration delay and a fixed read latency.
-- Only the low 1 MiB is backed. The image file holds "AAAAA BB" hex lines.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity migui_model is
  generic (
    IMAGE_FILE : string := "image.hex";
    FINAL_FILE : string := "";             -- expected changes at the end
    CALIB_CYCLES : natural := 200;
    READ_LATENCY : positive := 20
  );
  port (
    clk : in std_logic;
    init_calib_complete : out std_logic;
    app_addr : in std_logic_vector(27 downto 0);
    app_cmd : in std_logic_vector(2 downto 0);
    app_en : in std_logic;
    app_rdy : out std_logic;
    app_wdf_data : in std_logic_vector(127 downto 0);
    app_wdf_end, app_wdf_wren : in std_logic;
    app_wdf_mask : in std_logic_vector(15 downto 0);
    app_wdf_rdy : out std_logic;
    app_rd_data : out std_logic_vector(127 downto 0);
    app_rd_data_valid, app_rd_data_end : out std_logic;
    check : in std_logic;                    -- compare memory with FINAL_FILE
    check_done : out std_logic
  );
end;

architecture model of migui_model is
  signal calibrated, rdy, wdf_rdy : std_logic := '0';
begin
  init_calib_complete<=calibrated;
  app_rdy<=rdy; app_wdf_rdy<=wdf_rdy;

  process(clk)
    type memory_type is array(0 to 1048575) of std_logic_vector(7 downto 0);
    variable mem, expected : memory_type := (others=>(others=>'0'));
    constant depth : positive := 8;
    type cmd_queue is array(0 to depth-1) of std_logic_vector(28 downto 0); -- read flag & addr
    type data_queue is array(0 to depth-1) of std_logic_vector(143 downto 0); -- mask & data
    type read_queue is array(0 to depth-1) of std_logic_vector(127 downto 0);
    type due_queue is array(0 to depth-1) of natural;
    variable cq : cmd_queue; variable dq : data_queue;
    variable rq : read_queue; variable rdue : due_queue;
    variable cn, dn, rn : natural range 0 to depth := 0;
    variable cycle : natural := 0;
    variable lfsr : std_logic_vector(15 downto 0) := x"ACE1";
    variable loaded : boolean := false;
    variable done : std_logic := '0';
    variable base : natural;
    variable word : std_logic_vector(127 downto 0);
    variable entry : std_logic_vector(143 downto 0);
    file image : text;
    variable row : line;
    variable addr : std_logic_vector(19 downto 0);
    variable value : std_logic_vector(7 downto 0);
  begin
    if not loaded then
      if IMAGE_FILE'length>0 then
        file_open(image, IMAGE_FILE, read_mode);
        while not endfile(image) loop
          readline(image,row); hread(row,addr); hread(row,value);
          mem(to_integer(unsigned(addr))):=value;
        end loop;
        file_close(image);
      end if;
      expected:=mem;
      if FINAL_FILE'length>0 then
        file_open(image, FINAL_FILE, read_mode);
        while not endfile(image) loop
          readline(image,row); hread(row,addr); hread(row,value);
          expected(to_integer(unsigned(addr))):=value;
        end loop;
        file_close(image);
      end if;
      loaded:=true;
    end if;
    if rising_edge(clk) then
      cycle:=cycle+1;
      lfsr:=lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      -- Accept on this edge using the ready values the DUT saw.
      if app_en='1' and rdy='1' then
        assert app_cmd="000" or app_cmd="001" report "unsupported MIG command" severity failure;
        assert unsigned(app_addr(2 downto 0))=0 report "unaligned BL8 address" severity failure;
        assert unsigned(app_addr(27 downto 19))=0 report "address outside modeled 1MiB" severity failure;
        cq(cn):=app_cmd(0) & app_addr; cn:=cn+1;
      end if;
      if app_wdf_wren='1' and wdf_rdy='1' then
        assert app_wdf_end='1' report "4:1 write needs app_wdf_end with each beat" severity failure;
        dq(dn):=app_wdf_mask & app_wdf_data; dn:=dn+1;
      end if;
      -- Execute the oldest command in order.
      if cn>0 then
        base:=2*to_integer(unsigned(cq(0)(27 downto 0)));
        if cq(0)(28)='1' then
          if rn<depth then
            for k in 0 to 15 loop word(8*k+7 downto 8*k):=mem(base+k); end loop;
            rq(rn):=word; rdue(rn):=cycle+READ_LATENCY; rn:=rn+1;
            cq(0 to depth-2):=cq(1 to depth-1); cn:=cn-1;
          end if;
        elsif dn>0 then
          entry:=dq(0);
          for k in 0 to 15 loop
            if entry(128+k)='0' then mem(base+k):=entry(8*k+7 downto 8*k); end if;
          end loop;
          dq(0 to depth-2):=dq(1 to depth-1); dn:=dn-1;
          cq(0 to depth-2):=cq(1 to depth-1); cn:=cn-1;
        end if;
      end if;
      app_rd_data_valid<='0'; app_rd_data_end<='0';
      if rn>0 and cycle>=rdue(0) then
        app_rd_data<=rq(0); app_rd_data_valid<='1'; app_rd_data_end<='1';
        rq(0 to depth-2):=rq(1 to depth-1); rdue(0 to depth-2):=rdue(1 to depth-1); rn:=rn-1;
      end if;
      if cycle>=CALIB_CYCLES then calibrated<='1'; end if;
      -- About one cycle in four is stalled on each ready.
      if cycle>=CALIB_CYCLES and cn<depth-2 and lfsr(1 downto 0)/="00" then rdy<='1'; else rdy<='0'; end if;
      if cycle>=CALIB_CYCLES and dn<depth-2 and lfsr(3 downto 2)/="00" then wdf_rdy<='1'; else wdf_rdy<='0'; end if;
      if check='1' and done='0' then
        for k in mem'range loop
          assert mem(k)=expected(k)
            report "final memory mismatch at " & integer'image(k) severity failure;
        end loop;
        done:='1';
      end if;
      check_done<=done;
    end if;
  end process;
end;
