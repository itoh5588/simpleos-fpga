-- SPDX-License-Identifier: MIT
-- Byte port (MMU physical side) to a Xilinx 7-series MIG native UI for
-- x16 DDR3 with 4:1 PHY ratio (128-bit UI data, BL8 = 16 bytes/command).
-- Runs in the MIG ui_clk domain. One request outstanding at a time.
-- A single 16-byte line read buffer is kept coherent by write-through.
-- The MIG must use STRICT ordering so a read after a write sees new data.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity simpleos_ddr3 is
  generic (APP_ADDR_WIDTH : positive := 28);
  port (
    clk, reset : in std_logic;
    mem_valid, mem_write : in std_logic;   -- held until mem_ready
    mem_addr : in unsigned(19 downto 0);   -- byte address
    mem_wdata : in unsigned(7 downto 0);
    mem_ready : out std_logic;             -- one-cycle completion pulse
    mem_rdata : out unsigned(7 downto 0);  -- valid while mem_ready='1'
    app_addr : out std_logic_vector(APP_ADDR_WIDTH-1 downto 0);
    app_cmd : out std_logic_vector(2 downto 0);
    app_en : out std_logic;
    app_rdy : in std_logic;
    app_wdf_data : out std_logic_vector(127 downto 0);
    app_wdf_end, app_wdf_wren : out std_logic;
    app_wdf_mask : out std_logic_vector(15 downto 0); -- '1' = byte not written
    app_wdf_rdy : in std_logic;
    app_rd_data : in std_logic_vector(127 downto 0);
    app_rd_data_valid : in std_logic
  );
end;

architecture rtl of simpleos_ddr3 is
  type states is (idle, write_issue, read_issue, read_wait, respond);
  signal state : states := idle;
  signal req_addr : unsigned(19 downto 0) := (others=>'0');
  signal cmd_pending, data_pending, line_valid : std_logic := '0';
  signal line_tag : unsigned(15 downto 0) := (others=>'0');
  signal line_data, wdf_data : std_logic_vector(127 downto 0) := (others=>'0');
  signal wdf_mask : std_logic_vector(15 downto 0) := (others=>'1');
  signal rdata : unsigned(7 downto 0) := (others=>'0');

  function lane(line : std_logic_vector(127 downto 0); i : natural) return unsigned is
  begin
    return unsigned(line(8*i+7 downto 8*i));
  end;
begin
  mem_ready<='1' when state=respond else '0';
  mem_rdata<=rdata;
  -- MIG addresses x16 columns; a BL8 burst covers 8 columns = 16 bytes.
  app_addr<=std_logic_vector(resize(req_addr(19 downto 4) & "000", APP_ADDR_WIDTH));
  app_cmd<="000" when state=write_issue else "001";
  app_en<=cmd_pending;
  app_wdf_wren<=data_pending;
  app_wdf_end<=data_pending;
  app_wdf_data<=wdf_data;
  app_wdf_mask<=wdf_mask;

  process(clk)
    variable i : natural range 0 to 15;
    variable cmd_left, data_left : std_logic;
  begin
    if rising_edge(clk) then
      if reset='1' then
        state<=idle; line_valid<='0'; cmd_pending<='0'; data_pending<='0';
      else
        case state is
          when idle =>
            if mem_valid='1' then
              req_addr<=mem_addr;
              i:=to_integer(mem_addr(3 downto 0));
              if mem_write='1' then
                for k in 0 to 15 loop
                  wdf_data(8*k+7 downto 8*k)<=std_logic_vector(mem_wdata);
                end loop;
                wdf_mask<=(others=>'1'); wdf_mask(i)<='0';
                if line_valid='1' and line_tag=mem_addr(19 downto 4) then
                  line_data(8*i+7 downto 8*i)<=std_logic_vector(mem_wdata);
                end if;
                cmd_pending<='1'; data_pending<='1'; state<=write_issue;
              elsif line_valid='1' and line_tag=mem_addr(19 downto 4) then
                rdata<=lane(line_data,i); state<=respond;
              else
                cmd_pending<='1'; state<=read_issue;
              end if;
            end if;
          when write_issue =>
            -- Command and data are accepted independently by the MIG.
            cmd_left:=cmd_pending and not app_rdy;
            data_left:=data_pending and not app_wdf_rdy;
            cmd_pending<=cmd_left; data_pending<=data_left;
            if cmd_left='0' and data_left='0' then state<=respond; end if;
          when read_issue =>
            if app_rdy='1' then cmd_pending<='0'; state<=read_wait; end if;
          when read_wait =>
            if app_rd_data_valid='1' then
              line_data<=app_rd_data; line_tag<=req_addr(19 downto 4); line_valid<='1';
              rdata<=lane(app_rd_data,to_integer(req_addr(3 downto 0)));
              state<=respond;
            end if;
          when respond =>
            state<=idle;
        end case;
      end if;
    end if;
  end process;
end;
