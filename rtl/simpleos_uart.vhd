library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- 8N1 UART with a two-flop input synchronizer and a one-byte receive buffer.
entity simpleos_uart is
  generic (CLOCK_HZ : positive := 100000000; BAUD : positive := 115200);
  port (clk,reset : in std_logic; rxd : in std_logic; txd : out std_logic;
        tx_valid : in std_logic; tx_ready : out std_logic;
        tx_data : in unsigned(7 downto 0);
        rx_valid : out std_logic; rx_ready : in std_logic;
        rx_data : out unsigned(7 downto 0);
        framing_error,overrun : out std_logic);
end;
architecture rtl of simpleos_uart is
  constant DIVISOR : positive := (CLOCK_HZ+BAUD/2)/BAUD;
  signal sync1,sync2 : std_logic := '1';
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of sync1,sync2 : signal is "TRUE";
  signal tx_shift : std_logic_vector(9 downto 0) := (others=>'1');
  signal tx_busy : std_logic := '0';
  signal tx_count : natural range 0 to DIVISOR-1 := 0;
  signal tx_bit : natural range 0 to 9 := 0;
  type rx_states is (idle,start_bit,data_bits,stop_bit,recover);
  signal rx_state : rx_states := idle;
  signal rx_count : natural range 0 to DIVISOR-1 := 0;
  signal rx_bit : natural range 0 to 7 := 0;
  signal rx_shift,buffer_data : unsigned(7 downto 0) := (others=>'0');
  signal buffer_valid,bad_frame,lost : std_logic := '0';
begin
  assert DIVISOR>=4 report "UART needs at least four clocks per bit" severity failure;
  tx_ready<=not tx_busy; txd<=tx_shift(0) when tx_busy='1' else '1';
  rx_valid<=buffer_valid; rx_data<=buffer_data;
  framing_error<=bad_frame; overrun<=lost;
  process(clk)
  begin
    if rising_edge(clk) then
      sync1<=rxd; sync2<=sync1;
      if reset='1' then
        sync1<='1'; sync2<='1'; tx_busy<='0'; tx_shift<=(others=>'1');
        tx_count<=0; tx_bit<=0; rx_state<=idle; buffer_valid<='0';
        bad_frame<='0'; lost<='0'; rx_count<=0; rx_bit<=0;
      else
        if buffer_valid='1' and rx_ready='1' then buffer_valid<='0'; end if;
        if tx_busy='0' then
          if tx_valid='1' then
            tx_shift<='1' & std_logic_vector(tx_data) & '0';
            tx_busy<='1'; tx_count<=DIVISOR-1; tx_bit<=0;
          end if;
        elsif tx_count=0 then
          if tx_bit=9 then tx_busy<='0';
          else
            tx_shift<='1' & tx_shift(9 downto 1);
            tx_bit<=tx_bit+1; tx_count<=DIVISOR-1;
          end if;
        else tx_count<=tx_count-1; end if;
        case rx_state is
          when idle =>
            if sync2='0' then rx_count<=DIVISOR/2-1; rx_state<=start_bit; end if;
          when start_bit =>
            if rx_count=0 then
              if sync2='0' then rx_count<=DIVISOR-1; rx_bit<=0; rx_state<=data_bits;
              else rx_state<=idle; end if;
            else rx_count<=rx_count-1; end if;
          when data_bits =>
            if rx_count=0 then
              rx_shift(rx_bit)<=sync2; rx_count<=DIVISOR-1;
              if rx_bit=7 then rx_state<=stop_bit; else rx_bit<=rx_bit+1; end if;
            else rx_count<=rx_count-1; end if;
          when stop_bit =>
            if rx_count=0 then
              if sync2='1' then
                if buffer_valid='0' or rx_ready='1' then
                  buffer_data<=rx_shift; buffer_valid<='1';
                else lost<='1'; end if;
                rx_state<=idle;
              else bad_frame<='1'; rx_state<=recover; end if;
            else rx_count<=rx_count-1; end if;
          when recover => if sync2='1' then rx_state<=idle; end if;
        end case;
      end if;
    end if;
  end process;
end;
