library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;
entity tb_simpleos_board is end;
architecture test of tb_simpleos_board is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal rxd,txd : std_logic := '1';
  signal leds : std_logic_vector(3 downto 0);
  type bytes_type is array(0 to 1023) of unsigned(7 downto 0);
  signal output : bytes_type;
  signal output_count : natural := 0;
  component simpleos_board is
    generic (CLOCK_HZ : positive := 100000000; BAUD : positive := 115200);
    port (I_CLK100,I_RESET,I_RXD : in std_logic;
          O_TXD : out std_logic; O_LED : out std_logic_vector(3 downto 0));
  end component;
  constant bit_time : time := 8680 ns;
begin
  clk<=not clk after 5 ns;
  dut: simpleos_board
    port map(clk,reset,rxd,txd,leds);
  process
    variable value : unsigned(7 downto 0);
  begin
    wait until falling_edge(txd); wait for bit_time*3/2;
    for i in 0 to 7 loop value(i):=txd; wait for bit_time; end loop;
    assert txd='1' report "invalid TX stop" severity failure;
    output(output_count)<=value; output_count<=output_count+1;
  end process;
  process
    file image : text open read_mode is "sample.hex";
    variable row : line;
    variable program : bytes_type;
    variable size : natural := 0;
    variable sum : unsigned(7 downto 0) := (others=>'0');
    variable previous_count : natural;
    constant expected : string := "Hello from Simple OS CPU on Arty S7!" & character'val(10) &
                                  "MUL/DIV PASS; LEDs=5" & character'val(10);
    procedure send(value : unsigned(7 downto 0)) is
    begin
      rxd<='0'; wait for bit_time;
      for i in 0 to 7 loop rxd<=value(i); wait for bit_time; end loop;
      rxd<='1'; wait for bit_time;
    end;
  begin
    while not endfile(image) loop
      readline(image,row); hread(row,program(size)); sum:=sum+program(size); size:=size+1;
    end loop;
    wait for 100 ns; reset<='0'; wait until output_count=1;
    assert output(0)=66 report "missing boot B" severity failure;
    send(to_unsigned(82,8)); wait until output_count=2;
    assert output(1)=69 report "run-before-load not rejected" severity failure;
    send(to_unsigned(87,8)); send(to_unsigned(0,8)); send(to_unsigned(0,8));
    wait until output_count=3;
    assert output(2)=69 report "empty image not rejected" severity failure;
    send(to_unsigned(87,8)); send(to_unsigned(32,8)); send(to_unsigned(1,8));
    wait until output_count=4;
    assert output(3)=69 report "oversized image not rejected" severity failure;
    send(to_unsigned(87,8)); send(to_unsigned(size/256,8)); send(to_unsigned(size mod 256,8));
    for i in 0 to size-1 loop send(program(i)); end loop;
    send(sum+1); wait until output_count=5;
    assert output(4)=69 report "checksum error not rejected" severity failure;
    send(to_unsigned(87,8)); send(to_unsigned(size/256,8)); send(to_unsigned(size mod 256,8));
    for i in 0 to size-1 loop send(program(i)); end loop;
    send(sum); wait until output_count=6;
    assert output(5)=75 report "valid upload not acknowledged" severity failure;
    send(to_unsigned(82,8));
    wait until output_count=7+expected'length;
    for i in expected'range loop
      assert output(5+i)=character'pos(expected(i)) report "sample UART output mismatch at " & integer'image(i) & " actual " & to_hstring(output(5+i)) & " expected " & integer'image(character'pos(expected(i))) severity failure;
    end loop;
    assert output(6+expected'length)=4 report "missing HALT EOT" severity failure;
    assert leds="0101" report "SYSCALL 50 LED mismatch" severity failure;
    report "PASS: loader rejects invalid images; CPU UART string, sequential MUL/DIV, LED=5 and HALT";
    -- Start a genuine non-halting CPU loop, then interrupt it with serial BREAK.
    previous_count:=output_count;
    send(to_unsigned(87,8)); send(to_unsigned(0,8)); send(to_unsigned(4,8));
    send(to_unsigned(16#68#,8)); send(to_unsigned(8,8));
    send(to_unsigned(0,8)); send(to_unsigned(0,8)); send(to_unsigned(16#70#,8));
    wait until output_count=previous_count+1;
    assert output(previous_count)=75 report "loop upload failed" severity failure;
    send(to_unsigned(82,8)); wait for 300 us;
    assert output_count=previous_count+1 report "loop unexpectedly halted" severity failure;
    rxd<='0'; wait for 300 us; rxd<='1';
    wait until output_count=previous_count+2;
    assert output(previous_count+1)=66 report "BREAK did not return boot B" severity failure;
    send(to_unsigned(87,8)); send(to_unsigned(size/256,8)); send(to_unsigned(size mod 256,8));
    for i in 0 to size-1 loop send(program(i)); end loop;
    send(sum);
    wait until output_count=previous_count+3;
    assert output(previous_count+2)=75 report "upload after BREAK rejected" severity failure;
    send(to_unsigned(82,8));
    wait until output_count=previous_count+4+expected'length;
    for i in expected'range loop
      assert output(previous_count+2+i)=character'pos(expected(i)) report "post-BREAK output mismatch" severity failure;
    end loop;
    assert output(previous_count+3+expected'length)=4 report "post-BREAK HALT missing" severity failure;
    report "PASS: UART BREAK stops running CPU; reupload and rerun succeed on the same connection";
    finish;
  end process;
  process begin wait for 100 ms; assert false report "board simulation timeout" severity failure; end process;
end;
