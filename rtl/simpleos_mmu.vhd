library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Byte-serial memory adapter. Snapshot all sixteen page entries once per
-- instruction, retaining that snapshot during exception entry and IRET.
entity simpleos_mmu is
  port (
    clk, reset : in std_logic;
    reload, enabled : in std_logic;
    page_table : in unsigned(19 downto 0);
    reload_ready : out std_logic;
    logical_valid, logical_write : in std_logic;
    logical_addr : in unsigned(19 downto 0);
    logical_size : in unsigned(2 downto 0);
    logical_wdata : in unsigned(31 downto 0);
    logical_ready, logical_fault : out std_logic;
    logical_rdata : out unsigned(31 downto 0);
    fault_addr : out unsigned(19 downto 0);
    physical_valid, physical_write : out std_logic;
    physical_addr : out unsigned(19 downto 0);
    physical_size : out unsigned(2 downto 0);
    physical_wdata : out unsigned(31 downto 0);
    physical_ready : in std_logic;
    physical_rdata : in unsigned(31 downto 0)
  );
end;
architecture rtl of simpleos_mmu is
  type table_type is array(0 to 15) of unsigned(7 downto 0);
  signal pages : table_type := (others=>(others=>'0'));
  type states is (idle, table_read, table_done, translate, byte_transfer, response);
  signal state : states := idle;
  signal table_base, start_addr, bus_addr, failed_addr : unsigned(19 downto 0) := (others=>'0');
  signal table_index : integer range 0 to 15 := 0;
  signal offset : integer range 0 to 3 := 0;
  signal count : integer range 1 to 4 := 4;
  signal writing, mode, failed : std_logic := '0';
  signal write_value, read_value : unsigned(31 downto 0) := (others=>'0');
begin
  reload_ready<='1' when state=table_done else '0';
  logical_ready<='1' when state=response else '0';
  logical_fault<=failed;
  logical_rdata<=read_value; fault_addr<=failed_addr;
  physical_valid<='1' when state=table_read or state=byte_transfer else '0';
  physical_write<=writing when state=byte_transfer else '0';
  physical_addr<=table_base+to_unsigned(table_index,20) when state=table_read else bus_addr;
  physical_size<=to_unsigned(1,3);
  physical_wdata<=(shift_right(write_value,8*(count-1-offset)) and x"000000FF");
  process(clk)
    variable address : unsigned(19 downto 0);
    variable ppn : unsigned(7 downto 0);
    variable combined : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if reset='1' then
        state<=idle; failed<='0'; mode<='0'; offset<=0;
      else
        case state is
          when idle =>
            if reload='1' then
              mode<=enabled; table_base<=page_table; table_index<=0;
              if enabled='1' then state<=table_read; else state<=table_done; end if;
            elsif logical_valid='1' then
              assert logical_size=1 or logical_size=2 or logical_size=4
                report "invalid logical transfer size" severity failure;
              start_addr<=logical_addr; count<=to_integer(logical_size);
              writing<=logical_write; write_value<=logical_wdata;
              read_value<=(others=>'0'); offset<=0; failed<='0'; state<=translate;
            end if;
          when table_read =>
            if physical_ready='1' then
              pages(table_index)<=physical_rdata(7 downto 0);
              if table_index=15 then state<=table_done;
              else table_index<=table_index+1; end if;
            end if;
          when table_done =>
            if reload='0' then state<=idle; end if;
          when translate =>
            address:=start_addr+to_unsigned(offset,20);
            ppn:=resize(address(19 downto 16),8);
            if mode='1' then ppn:=pages(to_integer(address(19 downto 16))); end if;
            if ppn=x"FF" then
              failed<='1'; failed_addr<=address; state<=response;
            else
              assert ppn<16 report "physical page outside 1MiB" severity failure;
              bus_addr<=ppn(3 downto 0) & address(15 downto 0);
              state<=byte_transfer;
            end if;
          when byte_transfer =>
            if physical_ready='1' then
              combined:=shift_left(read_value,8);
              combined(7 downto 0):=physical_rdata(7 downto 0);
              read_value<=combined;
              if offset=count-1 then state<=response;
              else offset<=offset+1; state<=translate; end if;
            end if;
          when response => state<=idle;
        end case;
      end if;
    end if;
  end process;
end;
