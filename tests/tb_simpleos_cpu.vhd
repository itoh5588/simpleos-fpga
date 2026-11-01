library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;
entity tb_simpleos_cpu is end;
architecture test of tb_simpleos_cpu is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal mv,mw,mready,hv,hready,hwrite,halted,failed : std_logic := '0';
  signal ma,hn : unsigned(19 downto 0);
  signal ms : unsigned(2 downto 0);
  signal wd,rd,h8,h9,hresult,debug : unsigned(31 downto 0) := (others=>'0');
  signal di : unsigned(3 downto 0) := (others=>'0');
  signal cycles : natural := 0;
begin
  clk <= not clk after 5 ns;
  dut: entity work.simpleos_cpu port map(clk,reset,mv,mw,ma,ms,wd,mready,rd,
      hv,hn,h8,h9,hready,hwrite,hresult,halted,failed,di,debug,
      irq_ack=>open, mmu_reload=>open, mmu_enabled=>open, page_table=>open);
  mready <= '1' when cycles mod 3=0 else '0';
  process
    type memory_type is array(0 to 1048575) of std_logic_vector(7 downto 0);
    variable mem : memory_type := (others=>(others=>'0'));
    file input_file : text open read_mode is "program.hex";
    variable row : line;
    variable byte_value : std_logic_vector(7 downto 0);
    variable pos : natural := 16#80000#;
    variable address, count : natural;
    variable value, shifted : unsigned(31 downto 0);
  begin
    while not endfile(input_file) loop
      readline(input_file,row); hread(row,byte_value);
      mem(pos):=byte_value; pos:=pos+1;
    end loop;
    loop
      wait until falling_edge(clk);
      address:=to_integer(ma); count:=to_integer(ms);
      value:=(others=>'0');
      if mv='1' then
        assert address+count<=1048576 report "out of range" severity failure;
        for i in 0 to count-1 loop
          value:=shift_left(value,8); value(7 downto 0):=unsigned(mem(address+i));
        end loop;
      end if;
      rd<=value;
      wait until rising_edge(clk);
      if mv='1' and mready='1' and mw='1' then
        for i in 0 to count-1 loop
          shifted:=shift_right(wd,8*(count-1-i));
          mem(address+i):=std_logic_vector(shifted(7 downto 0));
        end loop;
      end if;
      cycles<=cycles+1;
    end loop;
  end process;
  process
    file expected_file : text open read_mode is "expected.hex";
    variable row : line;
    variable expected : std_logic_vector(31 downto 0);
    variable checkpoints : natural := 0;
  begin
    wait until falling_edge(clk); wait until falling_edge(clk); reset<='0';
    loop
      wait until rising_edge(clk);
      if hv='1' then
        assert hn=20 report "unexpected service" severity failure;
        assert not endfile(expected_file) report "extra checkpoint" severity failure;
        readline(expected_file,row);
        for i in 0 to 15 loop
          hread(row,expected); di<=to_unsigned(i,4); wait for 1 ns;
          assert debug=unsigned(expected)
            report "checkpoint " & integer'image(checkpoints) & " register " & integer'image(i)
              & " actual " & to_hstring(debug) & " expected " & to_hstring(expected)
            severity failure;
        end loop;
        checkpoints:=checkpoints+1;
        wait until falling_edge(clk); hready<='1';
        wait until rising_edge(clk); wait until falling_edge(clk); hready<='0';
      elsif halted='1' then
        assert failed='0' report "CPU faulted" severity failure;
        assert endfile(expected_file) report "missing checkpoints" severity failure;
        assert checkpoints>=20 report "wrong checkpoint count" severity failure;
        report "PASS: " & integer'image(checkpoints) & " checkpoints, " & integer'image(checkpoints*16) & " register comparisons";
        finish;
      end if;
    end loop;
  end process;
  process begin
    wait for 100 us;
    assert false report "simulation timeout" severity failure;
  end process;
end;
