library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;
entity tb_simpleos_system is end;
architecture test of tb_simpleos_system is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal lv,lw,lr,lf,pv,pw,pr,hv,hr,hw,halted,failed : std_logic := '0';
  signal reload,ready,enabled,irq,ack,inject,checked : std_logic := '0';
  signal la,pa,hn,pt,fa : unsigned(19 downto 0);
  signal ls,ps : unsigned(2 downto 0);
  signal ld,lread,pd,pread,h8,h9,hresult,debug : unsigned(31 downto 0) := (others=>'0');
  signal di : unsigned(3 downto 0) := (others=>'0');
  signal cycles : natural := 0;
  signal inject_count : natural range 0 to 15 := 0;
  signal pending : natural range 0 to 31 := 0;
begin
  clk<=not clk after 5 ns;
  cpu: entity work.simpleos_cpu port map(clk,reset,lv,lw,la,ls,ld,lr,lread,
    hv,hn,h8,h9,hr,hw,hresult,halted,failed,di,debug,
    mem_fault=>lf,mem_fault_addr=>fa,irq_valid=>irq,irq_number=>"00",irq_ack=>ack,
    mmu_reload=>reload,mmu_ready=>ready,mmu_enabled=>enabled,page_table=>pt);
  mmu: entity work.simpleos_mmu port map(clk,reset,reload,enabled,pt,ready,
    lv,lw,la,ls,ld,lr,lf,lread,fa,pv,pw,pa,ps,pd,pr,pread);
  pr<='1' when cycles mod 3=0 else '0';
  irq<='1' when pending>0 else '0';
  process(clk)
    variable next_pending : natural;
  begin
    if rising_edge(clk) then
      if reset='1' then pending<=0;
      else
        next_pending:=pending;
        if ack='1' and next_pending>0 then next_pending:=next_pending-1; end if;
        if inject='1' then next_pending:=next_pending+inject_count; end if;
        pending<=next_pending;
      end if;
    end if;
  end process;
  process
    type memory_type is array(0 to 1048575) of std_logic_vector(7 downto 0);
    variable mem,expected_mem : memory_type := (others=>(others=>'0'));
    file image : text open read_mode is "image.hex";
    file final_memory : text open read_mode is "final-memory.hex";
    variable row : line;
    variable addr : std_logic_vector(19 downto 0);
    variable byte_value : std_logic_vector(7 downto 0);
    variable address : natural;
  begin
    while not endfile(image) loop
      readline(image,row); hread(row,addr); hread(row,byte_value);
      mem(to_integer(unsigned(addr))):=byte_value;
    end loop;
    expected_mem:=mem;
    while not endfile(final_memory) loop
      readline(final_memory,row); hread(row,addr); hread(row,byte_value);
      expected_mem(to_integer(unsigned(addr))):=byte_value;
    end loop;
    loop
      wait until falling_edge(clk);
      address:=to_integer(pa); pread<=resize(unsigned(mem(address)),32);
      wait until rising_edge(clk);
      if pv='1' and pr='1' then
        assert ps=1 report "adapter must issue byte transfers" severity failure;
        if pw='1' then mem(address):=std_logic_vector(pd(7 downto 0)); end if;
      end if;
      cycles<=cycles+1;
      if halted='1' and checked='0' then
        for i in mem'range loop
          assert mem(i)=expected_mem(i)
            report "final memory mismatch at " & integer'image(i) severity failure;
        end loop;
        checked<='1';
      end if;
    end loop;
  end process;
  process
    file golden : text open read_mode is "expected.hex";
    variable row : line;
    variable number : std_logic_vector(19 downto 0);
    variable expected,result : std_logic_vector(31 downto 0);
    variable write_flag,irq_flag : std_logic_vector(3 downto 0);
    variable checkpoints : natural := 0;
  begin
    wait until falling_edge(clk); wait until falling_edge(clk); reset<='0';
    loop
      wait until rising_edge(clk);
      if hv='1' then
        assert not endfile(golden) report "extra service" severity failure;
        readline(golden,row); hread(row,number);
        assert hn=unsigned(number) report "service number mismatch" severity failure;
        for i in 0 to 15 loop
          hread(row,expected); di<=to_unsigned(i,4); wait for 1 ns;
          assert debug=unsigned(expected)
            report "checkpoint " & integer'image(checkpoints) & " register " & integer'image(i)
              & " actual " & to_hstring(debug) & " expected " & to_hstring(expected)
            severity failure;
        end loop;
        hread(row,write_flag); hread(row,result); hread(row,irq_flag);
        checkpoints:=checkpoints+1;
        wait until falling_edge(clk);
        hr<='1'; hw<=write_flag(0); hresult<=unsigned(result); inject<='1'; inject_count<=to_integer(unsigned(irq_flag));
        wait until rising_edge(clk); wait until falling_edge(clk);
        hr<='0'; hw<='0'; inject<='0';
      elsif halted='1' then
        assert failed='0' report "CPU faulted" severity failure;
        assert endfile(golden) report "missing services" severity failure;
        assert checkpoints>0 report "no checkpoints" severity failure;
        if checked='0' then wait until checked='1'; end if;
        report "PASS: " & integer'image(checkpoints) & " checkpoints, " & integer'image(checkpoints*16)
          & " register comparisons, full 1MiB final memory comparison";
        finish;
      end if;
    end loop;
  end process;
  process begin wait for 20 ms;
    assert false report "system simulation timeout" severity failure;
  end process;
end;
