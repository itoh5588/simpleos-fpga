library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- Arty S7 bring-up image: heartbeat plus 115200 8N1 serial echo.
-- It is intentionally separate from the CPU/DDR3 system.
entity simpleos_io_demo is
  generic (CLOCK_HZ : positive := 100000000; BAUD : positive := 115200;
           BLINK_CYCLES : positive := CLOCK_HZ/2);
  port (I_CLK100,I_RESET,I_RXD : in std_logic;
        O_TXD : out std_logic; O_LED : out std_logic_vector(3 downto 0));
end;
architecture rtl of simpleos_io_demo is
  signal reset_pipe : std_logic_vector(1 downto 0) := "11";
  signal reset : std_logic;
  signal rx_valid,tx_ready,frame_error,lost : std_logic;
  signal data : unsigned(7 downto 0);
  signal divider : natural range 0 to BLINK_CYCLES-1 := 0;
  signal blink,activity : std_logic := '0';
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of reset_pipe : signal is "TRUE";
begin
  -- Button assertion is asynchronous; deassertion is synchronized.
  process(I_CLK100,I_RESET) begin
    if I_RESET='1' then reset_pipe<="11";
    elsif rising_edge(I_CLK100) then reset_pipe<=reset_pipe(0)&'0'; end if;
  end process;
  reset<=reset_pipe(1);
  serial: entity work.simpleos_uart generic map(CLOCK_HZ,BAUD)
    port map(I_CLK100,reset,I_RXD,O_TXD,rx_valid,tx_ready,data,
             rx_valid,tx_ready,data,frame_error,lost);
  O_LED<=lost & frame_error & activity & blink;
  process(I_CLK100) begin
    if rising_edge(I_CLK100) then
      if reset='1' then divider<=0; blink<='0'; activity<='0';
      else
        if divider=BLINK_CYCLES-1 then divider<=0; blink<=not blink;
        else divider<=divider+1; end if;
        if rx_valid='1' and tx_ready='1' then activity<=not activity; end if;
      end if;
    end if;
  end process;
end;
