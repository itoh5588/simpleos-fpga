-- SPDX-License-Identifier: MIT
-- Simple OS system core in the MIG ui_clk domain: CPU, MMU, 100 ms timer,
-- DDR3 byte adapter and a UART monitor through which a PC host loads the
-- OS image and serves every SYSCALL except 41 (handled inside the CPU).
--
-- UART protocol (binary, big-endian fields):
--   FPGA -> PC  'B'                         ready, CPU stopped (after reset/BREAK)
--               'S' n(2) r8(4) r9(4)        SYSCALL n, CPU waits for 'C'
--               'H' status(1)               CPU halted, bit0 = fault stop; the stopped
--                                           CPU keeps its registers for W/R/G until BREAK
--   PC -> FPGA  'W' addr(3) len(2) data sum  physical write -> 'K' / 'E'
--               'R' addr(3) len(2)           physical read  -> data, sum
--               'G'                          16 registers (R0..R9,TP,SP,PC,PT,VT,CR) x 4
--               'C' flags(1) value(4)        finish SYSCALL: bit0 R8<=value,
--                                            bit1 push PC and jump to 0
--               'X'                          start the CPU (loader mode only)
--               'Z'                          zero all 1 MiB (loader mode only) -> 'K'
--   A UART BREAK (20 bit times low) resets the core back to 'B'.
-- W/R/G are accepted while the CPU is stopped or waiting in a SYSCALL; the
-- MMU is idle then, so the monitor owns the memory port. sum = 8-bit sum.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity simpleos_os_core is
  generic (
    CLOCK_HZ : positive := 81250000;
    BAUD : positive := 115200;
    TICK_CYCLES : positive := 8125000;   -- 100 ms timer at CLOCK_HZ
    APP_ADDR_WIDTH : positive := 28
  );
  port (
    clk, reset : in std_logic;            -- reset while the MIG is not calibrated
    rxd : in std_logic; txd : out std_logic;
    leds : out std_logic_vector(3 downto 0);
    app_addr : out std_logic_vector(APP_ADDR_WIDTH-1 downto 0);
    app_cmd : out std_logic_vector(2 downto 0);
    app_en : out std_logic;
    app_rdy : in std_logic;
    app_wdf_data : out std_logic_vector(127 downto 0);
    app_wdf_end, app_wdf_wren : out std_logic;
    app_wdf_mask : out std_logic_vector(15 downto 0);
    app_wdf_rdy : in std_logic;
    app_rd_data : in std_logic_vector(127 downto 0);
    app_rd_data_valid : in std_logic
  );
end;

architecture rtl of simpleos_os_core is
  constant BREAK_CYCLES : positive := 20*((CLOCK_HZ+BAUD/2)/BAUD);
  signal break_count : natural range 0 to BREAK_CYCLES := 0;
  signal line1, line2 : std_logic := '1';
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of line1, line2 : signal is "TRUE";
  signal core_reset, cpu_reset : std_logic;
  signal running, in_service, stopped, mon_active : std_logic := '0';
  -- UART
  signal tx_valid, tx_ready, rx_valid, rx_ready, frame_error, overrun : std_logic;
  signal tx_data, rx_data : unsigned(7 downto 0);
  -- CPU <-> MMU
  signal lv, lw, lr, lf, reload, reload_ready, mmu_on : std_logic;
  signal la, fa, pt, hn : unsigned(19 downto 0);
  signal ls : unsigned(2 downto 0);
  signal ld, lread, h8, h9, debug_value : unsigned(31 downto 0);
  signal host_valid, halted, faulted, ie, irq, irq_ack, timer_overflow : std_logic;
  signal debug_index : unsigned(3 downto 0) := (others=>'0');
  signal host_ready, host_write, host_call : std_logic := '0';
  signal host_result : unsigned(31 downto 0) := (others=>'0');
  -- MMU physical side and monitor, multiplexed onto the DDR3 adapter
  signal pv, pw, pr : std_logic;
  signal pa : unsigned(19 downto 0);
  signal ps : unsigned(2 downto 0);
  signal pd, pread : unsigned(31 downto 0);
  signal mon_valid, mon_write : std_logic := '0';
  signal mon_addr : unsigned(19 downto 0) := (others=>'0');
  signal mon_wdata : unsigned(7 downto 0) := (others=>'0');
  signal mem_valid, mem_write, mem_ready : std_logic;
  signal mem_addr : unsigned(19 downto 0);
  signal mem_wdata, mem_rdata : unsigned(7 downto 0);
  -- Monitor
  type states is (boot, idle, get_args, dispatch, w_data, w_mem, w_sum,
                  r_mem, r_next, g_load, g_take, g_next, z_mem, complete, run, send);
  signal state, after_send : states := boot;
  signal cmd : unsigned(7 downto 0) := (others=>'0');
  signal args : unsigned(39 downto 0) := (others=>'0');
  signal args_left : natural range 0 to 5 := 0;
  signal count : natural range 0 to 65535 := 0;
  signal sum : unsigned(7 downto 0) := (others=>'0');
  signal send_buf : unsigned(87 downto 0) := (others=>'0');
  signal send_left : natural range 0 to 11 := 0;
  signal reg_index : natural range 0 to 15 := 0;
  signal zero_left : natural range 0 to 1048576 := 0;
  constant C_B : unsigned(7 downto 0) := x"42";
  constant C_C : unsigned(7 downto 0) := x"43";
  constant C_E : unsigned(7 downto 0) := x"45";
  constant C_G : unsigned(7 downto 0) := x"47";
  constant C_H : unsigned(7 downto 0) := x"48";
  constant C_K : unsigned(7 downto 0) := x"4B";
  constant C_R : unsigned(7 downto 0) := x"52";
  constant C_S : unsigned(7 downto 0) := x"53";
  constant C_W : unsigned(7 downto 0) := x"57";
  constant C_X : unsigned(7 downto 0) := x"58";
  constant C_Z : unsigned(7 downto 0) := x"5A";
begin
  -- A sustained BREAK returns to the loader without closing the PC port.
  process(clk) begin
    if rising_edge(clk) then
      line1<=rxd; line2<=line1;
      if reset='1' or line2='1' then break_count<=0;
      elsif break_count<BREAK_CYCLES then break_count<=break_count+1; end if;
    end if;
  end process;
  core_reset<='1' when reset='1' or break_count=BREAK_CYCLES else '0';
  cpu_reset<=core_reset or not running;
  leds<=(faulted or frame_error or overrun or timer_overflow) & in_service & (running and not stopped) & not core_reset;

  serial: entity work.simpleos_uart generic map(CLOCK_HZ,BAUD)
    port map(clk,core_reset,rxd,txd,tx_valid,tx_ready,tx_data,
             rx_valid,rx_ready,rx_data,frame_error,overrun);

  cpu: entity work.simpleos_cpu port map(
    clk=>clk, reset=>cpu_reset, mem_valid=>lv, mem_write=>lw, mem_addr=>la, mem_size=>ls,
    mem_wdata=>ld, mem_ready=>lr, mem_rdata=>lread,
    host_valid=>host_valid, host_number=>hn, host_r8=>h8, host_r9=>h9,
    host_ready=>host_ready, host_write_r8=>host_write, host_result=>host_result,
    halted=>halted, faulted=>faulted, debug_index=>debug_index, debug_value=>debug_value,
    mem_fault=>lf, mem_fault_addr=>fa, irq_valid=>irq, irq_number=>"00", irq_ack=>irq_ack,
    mmu_reload=>reload, mmu_ready=>reload_ready, mmu_enabled=>mmu_on, page_table=>pt,
    interrupts_enabled=>ie, host_call=>host_call);

  mmu: entity work.simpleos_mmu port map(clk,cpu_reset,reload,mmu_on,pt,reload_ready,
    lv,lw,la,ls,ld,lr,lf,lread,fa,pv,pw,pa,ps,pd,pr,pread);

  timer: entity work.simpleos_timer generic map(CLOCK_HZ=>CLOCK_HZ, TICK_CYCLES=>TICK_CYCLES)
    port map(clk=>clk, reset=>cpu_reset, enabled=>ie, ack=>irq_ack,
             irq_valid=>irq, overflow=>timer_overflow);

  -- The monitor owns memory only while the CPU is reset, halted or in a SYSCALL.
  mon_active<=not running or in_service or stopped;
  mem_valid<=mon_valid when mon_active='1' else pv;
  mem_write<=mon_write when mon_active='1' else pw;
  mem_addr<=mon_addr when mon_active='1' else pa;
  mem_wdata<=mon_wdata when mon_active='1' else pd(7 downto 0);
  pr<=mem_ready and not mon_active;
  pread<=resize(mem_rdata,32);

  ddr: entity work.simpleos_ddr3 generic map(APP_ADDR_WIDTH=>APP_ADDR_WIDTH)
    port map(clk,core_reset,mem_valid,mem_write,mem_addr,mem_wdata,mem_ready,mem_rdata,
             app_addr,app_cmd,app_en,app_rdy,app_wdf_data,app_wdf_end,app_wdf_wren,
             app_wdf_mask,app_wdf_rdy,app_rd_data,app_rd_data_valid);

  tx_valid<='1' when state=send and send_left>0 else '0';
  tx_data<=send_buf(87 downto 80);
  rx_ready<='1' when state=idle or state=get_args or state=w_data or state=w_sum else '0';
  host_ready<='1' when state=complete else '0';

  process(clk)
    variable length : natural range 0 to 65535;
  begin
    if rising_edge(clk) then
      if core_reset='1' then
        state<=boot; running<='0'; in_service<='0'; stopped<='0'; mon_valid<='0'; send_left<=0;
      else
        case state is
          when boot =>
            send_buf(87 downto 80)<=C_B; send_left<=1; after_send<=idle; state<=send;
          when send =>
            if send_left=0 then state<=after_send;
            elsif tx_ready='1' then
              send_buf<=shift_left(send_buf,8); send_left<=send_left-1;
            end if;
          when idle =>
            if rx_valid='1' then
              cmd<=rx_data;
              if rx_data=C_W or rx_data=C_R or (rx_data=C_C and in_service='1') then
                args_left<=5; state<=get_args;
              elsif rx_data=C_G then
                reg_index<=0; state<=g_load;
              elsif rx_data=C_X and running='0' then
                running<='1'; state<=run;
              elsif rx_data=C_Z and running='0' then
                -- DDR3 powers up with random contents; the reference emulator
                -- starts from a zeroed 1 MiB memory.
                mon_addr<=(others=>'0'); mon_wdata<=(others=>'0'); mon_write<='1';
                mon_valid<='1'; zero_left<=1048576; state<=z_mem;
              else
                send_buf(87 downto 80)<=C_E; send_left<=1; after_send<=idle; state<=send;
              end if;
            end if;
          when get_args =>
            if rx_valid='1' then
              args<=args(31 downto 0) & rx_data;
              if args_left=1 then state<=dispatch; end if;
              args_left<=args_left-1;
            end if;
          when dispatch =>
            mon_addr<=args(35 downto 16);
            length:=to_integer(args(15 downto 0));
            count<=length; sum<=(others=>'0');
            if cmd=C_C then
              host_write<=args(32); host_call<=args(33); host_result<=args(31 downto 0);
              state<=complete;
            elsif cmd=C_W then
              if length=0 then state<=w_sum; else state<=w_data; end if;
            elsif length=0 then
              send_buf(87 downto 80)<=(others=>'0'); send_left<=1; after_send<=idle; state<=send;
            else
              mon_write<='0'; mon_valid<='1'; state<=r_mem;
            end if;
          when w_data =>
            if rx_valid='1' then
              mon_wdata<=rx_data; sum<=sum+rx_data;
              mon_write<='1'; mon_valid<='1'; state<=w_mem;
            end if;
          when w_mem =>
            if mem_ready='1' then
              mon_valid<='0'; mon_addr<=mon_addr+1; count<=count-1;
              if count=1 then state<=w_sum; else state<=w_data; end if;
            end if;
          when w_sum =>
            if rx_valid='1' then
              if rx_data=sum and frame_error='0' and overrun='0' then
                send_buf(87 downto 80)<=C_K;
              else
                send_buf(87 downto 80)<=C_E;
              end if;
              send_left<=1; after_send<=idle; state<=send;
            end if;
          when r_mem =>
            if mem_ready='1' then
              mon_valid<='0'; sum<=sum+mem_rdata;
              send_buf(87 downto 80)<=mem_rdata; send_left<=1; after_send<=r_next; state<=send;
            end if;
          when r_next =>
            mon_addr<=mon_addr+1; count<=count-1;
            if count=1 then
              send_buf(87 downto 80)<=sum; send_left<=1; after_send<=idle; state<=send;
            else
              mon_valid<='1'; state<=r_mem;
            end if;
          when z_mem =>
            if mem_ready='1' then
              mon_addr<=mon_addr+1; zero_left<=zero_left-1;
              if zero_left=1 then
                mon_valid<='0';
                send_buf(87 downto 80)<=C_K; send_left<=1; after_send<=idle; state<=send;
              end if;
            end if;
          when g_load =>
            debug_index<=to_unsigned(reg_index,4); state<=g_take;
          when g_take =>
            send_buf(87 downto 56)<=debug_value; send_left<=4; after_send<=g_next; state<=send;
          when g_next =>
            if reg_index=15 then state<=idle;
            else reg_index<=reg_index+1; state<=g_load; end if;
          when complete =>
            -- host_ready is high for this one cycle; the CPU leaves host_wait.
            in_service<='0'; host_call<='0'; state<=run;
          when run =>
            if halted='1' then
              stopped<='1';                -- keep the registers readable with 'G'
              send_buf(87 downto 72)<=C_H & "0000000" & faulted; send_left<=2;
              after_send<=idle; state<=send;
            elsif host_valid='1' then
              in_service<='1';
              send_buf<=C_S & hn(15 downto 0) & h8 & h9; send_left<=11;
              after_send<=idle; state<=send;
            end if;
        end case;
      end if;
    end if;
  end process;
end;
