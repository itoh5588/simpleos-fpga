library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- RAM bring-up system. No OS/MMU/DDR3 yet. UART: W,length(BE16),data,sum8;
-- K acknowledges a valid image, E rejects it. R executes, HALT emits EOT (04).
entity simpleos_board is
  generic (CLOCK_HZ : positive := 100000000; BAUD : positive := 115200);
  port (I_CLK100,I_RESET,I_RXD : in std_logic;
        O_TXD : out std_logic; O_LED : out std_logic_vector(3 downto 0));
end;
architecture rtl of simpleos_board is
  type ram_type is array(0 to 16383) of std_logic_vector(7 downto 0);
  signal ram : ram_type;
  signal ram_address : natural range 0 to 16383 := 0;
  signal ram_write : std_logic := '0';
  signal ram_in,ram_out : unsigned(7 downto 0) := (others=>'0');
  signal reset_pipe : std_logic_vector(1 downto 0) := "11";
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of reset_pipe : signal is "TRUE";
  constant BREAK_CYCLES : positive := 20*((CLOCK_HZ+BAUD/2)/BAUD);
  signal break_count : natural range 0 to BREAK_CYCLES := 0;
  signal console_sync1,console_sync2 : std_logic := '1';
  attribute ASYNC_REG of console_sync1,console_sync2 : signal is "TRUE";
  signal break_reset : std_logic;
  signal reset,cpu_reset,running,loaded : std_logic := '0';
  signal mv,mw,mready,hv,hready,hwrite,halted,failed : std_logic;
  signal ma,hn : unsigned(19 downto 0);
  signal ms : unsigned(2 downto 0);
  signal wd,rd,h8,h9,hresult : unsigned(31 downto 0) := (others=>'0');
  signal rxv,rxready,txv,txready,frame_error,lost : std_logic;
  signal rxdata,txdata : unsigned(7 downto 0);
  signal leds : std_logic_vector(3 downto 0) := (others=>'0');
  type state_type is (boot,idle,length_hi,length_lo,receive_data,checksum,
                     reply,execute_cpu,memory_read,memory_collect,memory_finish,
                     host_char,host_string,host_read,host_collect,host_send,
                     host_input,host_finish,stop_cpu);
  signal state,after_reply : state_type := boot;
  signal length_value : natural range 0 to 65535 := 0;
  signal received : natural range 0 to 8192 := 0;
  signal sum : unsigned(7 downto 0) := (others=>'0');
  signal address_value : unsigned(19 downto 0) := (others=>'0');
  signal transfer_size : natural range 1 to 4 := 1;
  signal byte_index : natural range 0 to 3 := 0;
  signal memory_write : std_logic := '0';
  signal write_value,read_value : unsigned(31 downto 0) := (others=>'0');
  function mapped(a : unsigned(19 downto 0)) return boolean is
  begin
    return (a>=16#80000# and a<=16#81FFF#) or a>=16#FE000#;
  end;
  function ram_index(a : unsigned(19 downto 0)) return natural is
  begin
    if a(18)='1' then return 8192+to_integer(a(12 downto 0));
    else return to_integer(a(12 downto 0)); end if;
  end;
begin
  process(I_CLK100,I_RESET) begin
    if I_RESET='1' then reset_pipe<="11";
    elsif rising_edge(I_CLK100) then reset_pipe<=reset_pipe(0)&'0'; end if;
  end process;
  -- A sustained UART BREAK returns to the loader without closing the terminal.
  process(I_CLK100) begin
    if rising_edge(I_CLK100) then
      console_sync1<=I_RXD; console_sync2<=console_sync1;
      if reset_pipe(1)='1' or console_sync2='1' then break_count<=0;
      elsif break_count<BREAK_CYCLES then break_count<=break_count+1; end if;
    end if;
  end process;
  break_reset<='1' when break_count=BREAK_CYCLES else '0';
  reset<=reset_pipe(1) or break_reset; cpu_reset<=reset or not running;
  O_LED<=leds;
  serial: entity work.simpleos_uart generic map(CLOCK_HZ,BAUD)
    port map(I_CLK100,reset,I_RXD,O_TXD,txv,txready,txdata,
             rxv,rxready,rxdata,frame_error,lost);
  cpu: entity work.simpleos_cpu port map(
    clk=>I_CLK100,reset=>cpu_reset,mem_valid=>mv,mem_write=>mw,
    mem_addr=>ma,mem_size=>ms,mem_wdata=>wd,mem_ready=>mready,mem_rdata=>rd,
    host_valid=>hv,host_number=>hn,host_r8=>h8,host_r9=>h9,
    host_ready=>hready,host_write_r8=>hwrite,host_result=>hresult,
    halted=>halted,faulted=>failed,debug_index=>(others=>'0'),debug_value=>open,
    irq_ack=>open,mmu_reload=>open,mmu_enabled=>open,page_table=>open);
  -- A single synchronous byte-wide RAM port is shared by CPU, loader and strings.
  process(I_CLK100) begin
    if rising_edge(I_CLK100) then
      ram_out<=unsigned(ram(ram_address));
      if ram_write='1' then ram(ram_address)<=std_logic_vector(ram_in); end if;
    end if;
  end process;
  txv<='1' when state=reply or state=host_char or state=host_send else '0';
  rxready<='1' when state=idle or state=length_hi or state=length_lo or
                       state=receive_data or state=checksum or state=host_input else '0';
  mready<='1' when state=memory_finish else '0';
  hready<='1' when state=host_finish else '0';
  process(I_CLK100)
    variable count : natural;
    variable next_read : unsigned(31 downto 0);
    variable current_address : unsigned(19 downto 0);
    variable shifted : unsigned(31 downto 0);
  begin
    if rising_edge(I_CLK100) then
      ram_write<='0';
      if reset='1' then
        state<=boot; running<='0'; loaded<='0'; leds<=(others=>'0');
        hwrite<='0'; received<=0; sum<=(others=>'0');
      else
        case state is
          when boot => txdata<=to_unsigned(66,8); after_reply<=idle; state<=reply; -- B: boot/loader ready
          when idle =>
            running<='0'; hwrite<='0';
            if rxv='1' then
              if rxdata=87 then loaded<='0'; state<=length_hi; -- W
              elsif rxdata=82 and loaded='1' then
                running<='1'; leds<=(others=>'0'); state<=execute_cpu;
              else txdata<=to_unsigned(69,8); after_reply<=idle; state<=reply; end if;
            end if;
          when length_hi =>
            if rxv='1' then length_value<=to_integer(rxdata)*256; state<=length_lo; end if;
          when length_lo =>
            if rxv='1' then
              count:=length_value+to_integer(rxdata);
              if count=0 or count>8192 then txdata<=to_unsigned(69,8); after_reply<=idle; state<=reply;
              else length_value<=count; received<=0; sum<=(others=>'0'); state<=receive_data; end if;
            end if;
          when receive_data =>
            if rxv='1' then
              ram_address<=received; ram_in<=rxdata; ram_write<='1';
              received<=received+1; sum<=sum+rxdata;
              if received+1=length_value then state<=checksum; end if;
            end if;
          when checksum =>
            if rxv='1' then
              if rxdata=sum and frame_error='0' and lost='0' then
                loaded<='1'; txdata<=to_unsigned(75,8); after_reply<=idle; state<=reply;
              else loaded<='0'; txdata<=to_unsigned(69,8); after_reply<=idle; state<=reply; end if;
            end if;
          when reply => if txready='1' then state<=after_reply; end if;
          when execute_cpu =>
            if halted='1' then
              running<='0';
              if failed='1' then leds(3)<='1'; txdata<=to_unsigned(21,8); after_reply<=idle; state<=reply;
              else txdata<=to_unsigned(4,8); after_reply<=idle; state<=reply; end if;
            elsif hv='1' then
              hwrite<='0';
              if hn=0 then txdata<=h8(7 downto 0); state<=host_char;
              elsif hn=1 then address_value<=h8(19 downto 0); state<=host_string;
              elsif hn=3 then state<=host_input;
              elsif hn=50 then leds<=std_logic_vector(h8(3 downto 0)); state<=host_finish;
              else running<='0'; leds(3)<='1'; txdata<=to_unsigned(21,8); after_reply<=idle; state<=reply; end if;
            elsif mv='1' then
              count:=to_integer(ms);
              if count/=1 and count/=2 and count/=4 then
                running<='0'; leds(3)<='1'; txdata<=to_unsigned(21,8); after_reply<=idle; state<=reply;
              elsif not mapped(ma) then
                running<='0'; leds(3)<='1'; txdata<=to_unsigned(21,8); after_reply<=idle; state<=reply;
              else
                address_value<=ma; transfer_size<=count; byte_index<=0;
                memory_write<=mw; write_value<=wd; read_value<=(others=>'0');
                ram_address<=ram_index(ma);
                if mw='1' then
                  shifted:=shift_right(wd,8*(count-1));
                  ram_in<=shifted(7 downto 0);
                  ram_write<='1';
                end if;
                state<=memory_read;
              end if;
            end if;
          when memory_read => state<=memory_collect;
          when memory_collect =>
            next_read:=shift_left(read_value,8); next_read(7 downto 0):=ram_out;
            read_value<=next_read;
            if byte_index+1=transfer_size then rd<=next_read; state<=memory_finish;
            else byte_index<=byte_index+1; state<=stop_cpu; end if;
          when stop_cpu =>
            current_address:=address_value+byte_index;
            if not mapped(current_address) then
              running<='0'; leds(3)<='1'; txdata<=to_unsigned(21,8); after_reply<=idle; state<=reply;
            else
              ram_address<=ram_index(current_address);
              if memory_write='1' then
                shifted:=shift_right(write_value,8*(transfer_size-1-byte_index));
                ram_in<=shifted(7 downto 0); ram_write<='1';
              end if;
              state<=memory_read;
            end if;
          when memory_finish => state<=execute_cpu;
          when host_char => if txready='1' then state<=host_finish; end if;
          when host_string =>
            if not mapped(address_value) then running<='0'; leds(3)<='1'; txdata<=to_unsigned(21,8); after_reply<=idle; state<=reply;
            else ram_address<=ram_index(address_value); state<=host_read; end if;
          when host_read => state<=host_collect;
          when host_collect =>
            if ram_out=0 then state<=host_finish;
            else txdata<=ram_out; state<=host_send; end if;
          when host_send =>
            if txready='1' then address_value<=address_value+1; state<=host_string; end if;
          when host_input =>
            if rxv='1' then hresult<=resize(rxdata,32); hwrite<='1'; state<=host_finish; end if;
          when host_finish => state<=execute_cpu;
        end case;
      end if;
    end if;
  end process;
end;
