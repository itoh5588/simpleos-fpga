library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity simpleos_timer is
  generic (CLOCK_HZ : positive := 100000000; TICK_CYCLES : positive := CLOCK_HZ/10;
           QUEUE_DEPTH : positive := 255);
  port (clk,reset,enabled,ack : in std_logic;
        irq_valid,overflow : out std_logic);
end;
architecture rtl of simpleos_timer is
  signal divider : natural range 0 to TICK_CYCLES-1 := 0;
  signal pending : natural range 0 to QUEUE_DEPTH := 0;
  signal lost : std_logic := '0';
begin
  irq_valid<='1' when pending>0 else '0'; overflow<=lost;
  process(clk)
    variable value : natural;
  begin
    if rising_edge(clk) then
      if reset='1' then divider<=0; pending<=0; lost<='0';
      else
        value:=pending;
        if ack='1' and value>0 then value:=value-1; end if;
        if divider=TICK_CYCLES-1 then
          divider<=0;
          if enabled='1' then
            if value<QUEUE_DEPTH then value:=value+1; else lost<='1'; end if;
          end if;
        else divider<=divider+1; end if;
        pending<=value;
      end if;
    end if;
  end process;
end;
