library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_simpleos_io is
  generic (BAUD : positive := 115200);
end;
architecture test of tb_simpleos_io is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal rxd,txd : std_logic := '1';
  signal leds : std_logic_vector(3 downto 0);
  signal buffered,frame_error,lost : std_logic;
  signal received : unsigned(7 downto 0);
  signal count,blink_edges : natural := 0;
  signal last_blink : std_logic := '0';
  signal timer_enable,timer_ack,timer_irq,timer_overflow,timer_done : std_logic := '0';
  type byte_array is array(natural range <>) of unsigned(7 downto 0);
  constant values : byte_array := (x"00",x"55",x"AA",x"FF",x"41");
  constant BIT_PERIOD : time := ((100000000+BAUD/2)/BAUD)*10 ns;
begin
  clk<=not clk after 5 ns;
  demo: entity work.simpleos_io_demo generic map(100000000,BAUD,20)
    port map(clk,reset,rxd,txd,leds);
  stalled_receiver: entity work.simpleos_uart generic map(100000000,BAUD)
    port map(clk,reset,rxd,open,'0',open,x"00",buffered,'0',received,frame_error,lost);
  timer: entity work.simpleos_timer generic map(100000000,10,3)
    port map(clk,reset,timer_enable,timer_ack,timer_irq,timer_overflow);
  process(clk) begin
    if rising_edge(clk) and reset='0' then
      if leds(0)/=last_blink then blink_edges<=blink_edges+1; end if;
      last_blink<=leds(0);
    end if;
  end process;
  -- Decode the wire manually, rather than trusting another UART transmitter.
  process
    variable value : unsigned(7 downto 0);
  begin
    for n in values'range loop
      wait until falling_edge(txd); wait for BIT_PERIOD/2;
      assert txd='0' report "missing start bit" severity failure;
      for bit in 0 to 7 loop
        wait for BIT_PERIOD; value(bit):=txd;
      end loop;
      wait for BIT_PERIOD;
      assert txd='1' report "bad transmitted stop bit" severity failure;
      assert value=values(n) report "UART echo mismatch" severity failure;
      report "echo " & integer'image(n) & " value " & to_hstring(value);
      count<=count+1;
    end loop;
    wait;
  end process;
  process
    procedure send(value : unsigned(7 downto 0); stop : std_logic := '1') is
    begin
      rxd<='0'; wait for BIT_PERIOD;
      for bit in 0 to 7 loop rxd<=value(bit); wait for BIT_PERIOD; end loop;
      rxd<=stop; wait for BIT_PERIOD; rxd<='1';
    end procedure;
  begin
    wait for 40 ns; reset<='0'; wait for 133 ns;
    -- A short false start must not produce a byte.
    rxd<='0'; wait for 20 ns; rxd<='1'; wait for 2*BIT_PERIOD;
    assert count=0 and buffered='0' report "false start accepted" severity failure;
    for n in values'range loop send(values(n)); end loop;
    wait for 12*BIT_PERIOD;
    assert count=5 report "missing echoed bytes: " & integer'image(count) & " LEDs " & to_hstring(leds) severity failure;
    assert leds(1)='1' report "activity LED did not toggle" severity failure;
    assert leds(3 downto 2)="00" report "echo path UART error" severity failure;
    assert buffered='1' and received=x"00" and lost='1'
      report "receive buffer/overrun behavior incorrect" severity failure;
    send(x"12",'0'); wait for 4*BIT_PERIOD;
    assert leds(2)='1' and frame_error='1' report "bad stop bit not detected" severity failure;
    assert blink_edges>10 report "heartbeat LED not blinking" severity failure;
    if timer_done='0' then wait until timer_done='1'; end if;
    report "PASS: UART echo 00/55/AA/FF/41, false start, framing error, overrun, LED heartbeat/activity, timer queue";
    finish;
  end process;
  process
    procedure clocks(n : natural) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
      wait for 1 ns;
    end;
  begin
    wait until reset='0'; clocks(40);
    assert timer_irq='0' report "disabled timer queued an interrupt" severity failure;
    timer_enable<='1'; clocks(40);
    assert timer_irq='1' and timer_overflow='1' report "timer queue accumulation/overflow missing" severity failure;
    timer_enable<='0'; timer_ack<='1'; clocks(3); timer_ack<='0';
    assert timer_irq='0' report "timer queue did not drain" severity failure;
    clocks(20); assert timer_irq='0' report "disabled ticks requeued" severity failure;
    timer_done<='1'; wait;
  end process;
  process begin wait for 2 ms; assert false report "IO timeout" severity failure; end process;
end;
