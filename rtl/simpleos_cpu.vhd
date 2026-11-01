library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Multi-cycle CPU with instruction-boundary MMU reload and exception frames.
-- Connect the logical memory interface to simpleos_mmu.
entity simpleos_cpu is
  port (
    clk, reset : in std_logic;
    mem_valid, mem_write : out std_logic;
    mem_addr : out unsigned(19 downto 0);
    mem_size : out unsigned(2 downto 0); -- bytes: 1, 2 or 4
    mem_wdata : out unsigned(31 downto 0);
    mem_ready : in std_logic;
    mem_rdata : in unsigned(31 downto 0);
    host_valid : out std_logic;
    host_number : out unsigned(19 downto 0);
    host_r8, host_r9 : out unsigned(31 downto 0);
    host_ready, host_write_r8 : in std_logic;
    host_result : in unsigned(31 downto 0);
    halted, faulted : out std_logic;
    debug_index : in unsigned(3 downto 0);
    debug_value : out unsigned(31 downto 0);
    mem_fault : in std_logic := '0';
    mem_fault_addr : in unsigned(19 downto 0) := (others=>'0');
    irq_valid : in std_logic := '0';
    irq_number : in unsigned(1 downto 0) := (others=>'0');
    irq_ack : out std_logic;
    mmu_reload : out std_logic;
    mmu_ready : in std_logic := '1';
    mmu_enabled : out std_logic;
    page_table : out unsigned(19 downto 0)
  );
end;
architecture rtl of simpleos_cpu is
  subtype word is unsigned(31 downto 0);
  type reg_array is array(0 to 15) of word;
  signal regs : reg_array := (others => (others => '0'));
  type state_type is (fetch_request, fetch_wait, execute, data_wait,
                     host_wait, reload_wait, arithmetic_wait, stopped);
  signal state : state_type := fetch_request;
  signal instruction : word := (others => '0');
  signal bus_addr : unsigned(19 downto 0) := (others => '0');
  signal bus_size : unsigned(2 downto 0) := to_unsigned(4,3);
  signal bus_data : word := (others => '0');
  signal bus_write : std_logic := '0';
  type continuation is (normal, load_register, pop_register, return_pc,
                       call_pc, iret_cr, irq_push_pc, irq_push_cr, irq_vector);
  signal action : continuation := normal;
  signal destination : integer range 0 to 15 := 0;
  signal branch_target : word := (others => '0');
  signal failed : std_logic := '0';
  signal mmu_mode : std_logic := '0';
  signal reload_request : std_logic := '0';
  signal exception_number : unsigned(1 downto 0) := (others=>'0');
  signal exception_active : std_logic := '0';
  signal pagefault_address : unsigned(19 downto 0) := (others=>'0');
  signal arith_op : integer range 5 to 7 := 5;
  signal arith_rd : integer range 0 to 15 := 0;
  signal arith_step : integer range 0 to 31 := 0;
  signal product, multiplicand : unsigned(63 downto 0) := (others=>'0');
  signal multiplier, quotient, divisor : word := (others=>'0');
  signal remainder_value : unsigned(32 downto 0) := (others=>'0');
  function taken(op : integer; cr : word) return boolean is
  begin
    case op is
      when 8 | 9 => return true;
      when 10 => return cr(2)='1';
      when 11 => return cr(2)='0';
      when 12 => return cr(1)='1';
      when 13 => return cr(1)='0';
      when 14 => return cr(0)='1';
      when 15 => return cr(0)='0';
      when others => return false;
    end case;
  end;
begin
  mmu_reload <= reload_request;
  mmu_enabled <= mmu_mode;
  page_table <= regs(13)(19 downto 0);
  mem_valid <= '1' when state=fetch_wait or state=data_wait else '0';
  mem_addr <= bus_addr;
  mem_size <= bus_size;
  mem_wdata <= bus_data;
  mem_write <= bus_write;
  host_valid <= '1' when state=host_wait else '0';
  host_number <= instruction(19 downto 0);
  host_r8 <= regs(8); host_r9 <= regs(9);
  halted <= '1' when state=stopped else '0';
  faulted <= failed;
  debug_value <= regs(to_integer(debug_index));
  process(clk)
    variable typ, op, rd, rs : integer;
    variable a, b, result, target, sp : word;
    variable wide : unsigned(63 downto 0);
    variable flags : word;
    variable remainder_next : unsigned(32 downto 0);
    variable quotient_next : word;
    variable arithmetic, writeback, valid : boolean;
    procedure enter_exception(number : unsigned(1 downto 0)) is
      variable stack_address : word;
    begin
      stack_address:=regs(11)-4;
      if regs(11)<4 then stack_address:=(others=>'0'); end if;
      regs(11)<=stack_address;
      bus_addr<=stack_address(19 downto 0); bus_size<=to_unsigned(4,3);
      bus_write<='1'; bus_data<=regs(12); action<=irq_push_pc;
      exception_number<=number; exception_active<='1'; state<=data_wait;
    end procedure;
  begin
    if rising_edge(clk) then
      irq_ack<='0';
      if reset='1' then
        regs <= (others => (others => '0'));
        regs(11) <= x"000FF000"; regs(12) <= x"00080000";
        state <= fetch_request; failed <= '0'; bus_write <= '0';
        mmu_mode<='0'; reload_request<='0'; exception_active<='0';
        pagefault_address<=(others=>'0');
      else
        case state is
          when fetch_request =>
            if irq_valid='1' and regs(15)(30)='1' then
              irq_ack<='1'; enter_exception(irq_number);
            else
              mmu_mode<=regs(15)(31); reload_request<='1';
              state<=reload_wait;
            end if;
          when reload_wait =>
            if mmu_ready='1' then
              reload_request<='0';
              bus_addr<=regs(12)(19 downto 0); bus_size<=to_unsigned(4,3);
              bus_write<='0'; state<=fetch_wait;
            end if;
          when fetch_wait =>
            if mem_ready='1' then
              if mem_fault='1' then
                pagefault_address<=mem_fault_addr; enter_exception(to_unsigned(3,2));
              else
                instruction<=mem_rdata; regs(12)<=regs(12)+4; state<=execute;
              end if;
            end if;
          when execute =>
            typ := to_integer(instruction(31 downto 28));
            op := to_integer(instruction(27 downto 24));
            rd := to_integer(instruction(23 downto 20));
            rs := to_integer(instruction(19 downto 16));
            a := regs(rd); b := resize(instruction(19 downto 0),32);
            state <= fetch_request;
            if typ=2 or typ=3 then b := regs(rs); end if;
            if typ=2 or typ=4 then
              arithmetic := true; writeback := true; valid := true;
              wide := (others => '0'); result := (others => '0');
              case op is
                when 0 => result := b; arithmetic := false;
                when 1 | 3 => wide := resize(a,64)+resize(b,64); result := wide(31 downto 0);
                when 2 | 4 => result := a-b;
                when 5 => null; -- Sequential multiply below.
                when 6 =>
                  if b=0 then valid := false; end if;
                when 7 =>
                  if b=0 then valid := false; end if;
                when 8 => result := a and b; arithmetic := false;
                when 9 => result := a or b; arithmetic := false;
                when 10 => result := a xor b; arithmetic := false;
                when others => valid := false;
              end case;
              if op=3 or op=4 then writeback := false; end if;
              if valid and op>=5 and op<=7 then
                arith_op<=op; arith_rd<=rd; arith_step<=0;
                product<=(others=>'0'); multiplicand<=resize(a,64); multiplier<=b;
                quotient<=a; divisor<=b; remainder_value<=(others=>'0');
                state<=arithmetic_wait;
              elsif valid then
                if arithmetic then
                  flags := regs(15) and x"F0000000";
                  if (op=2 or op=4) and a<b then flags(0):='1';
                  elsif wide(63 downto 32)/=0 then flags(1):='1';
                  elsif result=0 then flags(2):='1'; end if;
                  regs(15) <= flags;
                end if;
                if writeback then regs(rd) <= result; end if;
              else failed<='1'; state<=stopped; end if;
            elsif typ=3 or typ=5 then
              if op<=5 then
                bus_addr <= b(19 downto 0); bus_data <= a;
                bus_size <= to_unsigned(2**(op/2),3);
                bus_write <= instruction(24); destination <= rd;
                if op mod 2=0 then action<=load_register; else action<=normal; end if;
                state<=data_wait;
              else failed<='1'; state<=stopped; end if;
            elsif (typ=1 or typ=6) and op>=8 then
              target:=b; if typ=1 then target:=a; end if;
              if taken(op,regs(15)) then
                if op=9 then
                  sp := regs(11)-4;
                  if regs(11)<4 then sp:=(others=>'0'); end if;
                  regs(11)<=sp; bus_addr<=sp(19 downto 0);
                  bus_size<=to_unsigned(4,3); bus_data<=regs(12);
                  bus_write<='1'; branch_target<=target; action<=call_pc;
                  state<=data_wait;
                else regs(12)<=target; end if;
              end if;
            elsif typ=1 then
              case op is
                when 0 =>
                  sp:=regs(11)-4;
                  if regs(11)<4 then sp:=(others=>'0'); end if;
                  regs(11)<=sp; bus_addr<=sp(19 downto 0);
                  bus_size<=to_unsigned(4,3); bus_write<='1';
                  bus_data<=a;
                  action<=normal; state<=data_wait;
                when 1 =>
                  bus_addr<=regs(11)(19 downto 0); bus_size<=to_unsigned(4,3);
                  bus_write<='0'; destination<=rd; action<=pop_register;
                  state<=data_wait;
                when 2 | 3 =>
                  flags:=regs(15) and x"F0000000";
                  if op=2 then
                    result:=a+1;
                    if a=x"FFFFFFFF" then flags(1):='1'; end if;
                  else
                    result:=a-1;
                    if a=0 then flags(0):='1'; end if;
                  end if;
                  if result=0 and flags(1 downto 0)="00" then flags(2):='1'; end if;
                  regs(15)<=flags; regs(rd)<=result;
                when 4 => regs(rd)<=not a;
                when others => failed<='1'; state<=stopped;
              end case;
            elsif typ=0 then
              case op is
                when 0 => null;
                when 1 => state<=stopped;
                when 2 =>
                  bus_addr<=regs(11)(19 downto 0); bus_size<=to_unsigned(4,3);
                  bus_write<='0'; action<=return_pc; state<=data_wait;
                when 3 =>
                  bus_addr<=regs(11)(19 downto 0); bus_size<=to_unsigned(4,3);
                  bus_write<='0'; action<=iret_cr; state<=data_wait;
                when 4 => regs(15)(30)<='1';
                when 5 => regs(15)(30)<='0';
                when others => failed<='1'; state<=stopped;
              end case;
            elsif typ=6 and op=0 then
              if instruction(19 downto 0)=41 then
                regs(8)<=resize(pagefault_address,32);
              else state<=host_wait; end if;
            else failed<='1'; state<=stopped; end if;
          when arithmetic_wait =>
            wide:=product;
            quotient_next:=quotient;
            remainder_next:=remainder_value;
            if arith_op=5 then
              if multiplier(0)='1' then wide:=product+multiplicand; end if;
              product<=wide; multiplicand<=shift_left(multiplicand,1);
              multiplier<=shift_right(multiplier,1); result:=wide(31 downto 0);
            else
              remainder_next:=shift_left(remainder_value,1);
              remainder_next(0):=quotient(31);
              quotient_next:=shift_left(quotient,1);
              if remainder_next>=resize(divisor,33) then
                remainder_next:=remainder_next-resize(divisor,33); quotient_next(0):='1';
              end if;
              remainder_value<=remainder_next; quotient<=quotient_next;
              wide:=(others=>'0');
              if arith_op=6 then result:=quotient_next;
              else result:=remainder_next(31 downto 0); end if;
            end if;
            if arith_step=31 then
              flags:=regs(15) and x"F0000000";
              if arith_op=5 and wide(63 downto 32)/=0 then flags(1):='1';
              elsif result=0 then flags(2):='1'; end if;
              regs(15)<=flags; regs(arith_rd)<=result; state<=fetch_request;
            else arith_step<=arith_step+1; end if;
          when data_wait =>
            if mem_ready='1' then
              if mem_fault='1' then
                if exception_active='1' then failed<='1'; state<=stopped;
                else
                  pagefault_address<=mem_fault_addr; enter_exception(to_unsigned(3,2));
                end if;
              else
                state<=fetch_request;
                case action is
                  when normal => null;
                  when load_register => regs(destination)<=mem_rdata;
                  when pop_register =>
                    regs(11)<=regs(11)+4; regs(destination)<=mem_rdata;
                  when return_pc => regs(11)<=regs(11)+4; regs(12)<=mem_rdata;
                  when call_pc => regs(12)<=branch_target;
                  when iret_cr =>
                    regs(15)<=mem_rdata; regs(11)<=regs(11)+4;
                    bus_addr<=resize(regs(11)+4,20); bus_write<='0';
                    action<=return_pc; state<=data_wait;
                  when irq_push_pc =>
                    sp:=regs(11)-4;
                    if regs(11)<4 then sp:=(others=>'0'); end if;
                    regs(11)<=sp; bus_addr<=sp(19 downto 0);
                    bus_data<=regs(15); bus_write<='1';
                    action<=irq_push_cr; state<=data_wait;
                  when irq_push_cr =>
                    regs(15)(30)<='0'; bus_write<='0';
                    bus_addr<=resize(regs(14)+shift_left(resize(exception_number,32),2),20);
                    action<=irq_vector; state<=data_wait;
                  when irq_vector =>
                    regs(12)<=mem_rdata; exception_active<='0';
                end case;
              end if;
            end if;
          when host_wait =>
            if host_ready='1' then
              if host_write_r8='1' then regs(8)<=host_result; end if;
              state<=fetch_request;
            end if;
          when stopped => null;
        end case;
      end if;
    end if;
  end process;
end;
