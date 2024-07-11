-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2023 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Dmytro Khodarevskyi <xkhoda01 AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is

  type FSM is (
    S_START, -- inicializace
    
    S_FETCH, -- nacteni instrukce
    S_FETCH_WAIT, -- cekani na nacteni instrukce
    
    S_READ,   -- beh
    S_READ_WAIT, -- cekani na beh
    
    S_DONE, -- @    - 0x40 - Begin program

    S_PTR_READ, -- ptr read
    
    S_PTR_INC, -- ptr inc
    
    S_VALUE_INC1, -- +    - 0x2B - Increment value at ptr	           // *ptr+=1;
    S_VALUE_INC2, -- +    - 0x2B - Increment value at ptr	           // *ptr+=1;
    
    S_VALUE_DEC1, -- -    - 0x2D - Decrement value at ptr            // *ptr-=1;
    S_VALUE_DEC2, -- -    - 0x2D - Decrement value at ptr            // *ptr-=1;
    
    S_WHILE_START1, -- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
    S_WHILE_START1_5, -- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
    S_WHILE_START2, -- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
    S_WHILE_START2_5, -- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
    S_WHILE_START3, -- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
    S_WHILE_START4, -- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
    
    S_WHILE_END1, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END1_5, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END2, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END3, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END3_5, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END4, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END5, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END5_5, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    S_WHILE_END5_5_5, -- ]    - 0x5D - If not null byte, goto ], else +  // }
    
    S_WHILE_BREAK1, -- ~    - 0x7E - End of while                      // break;
    S_WHILE_BREAK2, -- ~    - 0x7E - End of while                      // break;
    S_WHILE_BREAK3, -- ~    - 0x7E - End of while                      // break;
    
    S_POINTER_INC, -- >    - 0x3E - Next symbol                       // ptr+=1;
    S_POINTER_DEC, -- <    - 0x3C - Previous symbol                   // ptr-=1;
    
    S_PUTCHAR1, -- .    - 0x2E - Print value at ptr                // printf("%d", *ptr);
    S_PUTCHAR2, -- .    - 0x2E - Print value at ptr                // printf("%d", *ptr);
    
    S_GETCHAR1, -- ,    - 0x2C - Read value and put it to ptr      // *ptr = getchar();
    S_GETCHAR1_5, -- ,    - 0x2C - Read value and put it to ptr      // *ptr = getchar();
    S_GETCHAR2, -- ,    - 0x2C - Read value and put it to ptr      // *ptr = getchar();
    S_GETCHAR3, -- ,    - 0x2C - Read value and put it to ptr      // *ptr = getchar();
    S_GETCHAR4, -- ,    - 0x2C - Read value and put it to ptr      // *ptr = getchar();
    
    S_INIT_DONE, -- null	- 0x00 - End program								       // return;
    S_HALT, -- null	- 0x00 - End program								       // return;
    S_CHECK_HALT -- null	- 0x00 - End program								       // return;
  );
  signal state : FSM := S_START;
  signal next_state : FSM := S_START;

  --init
  signal init : std_logic := '0';

  --pc
  signal pc_inc : std_logic := '0';
  signal pc_dec : std_logic := '0';
  signal pc_reg : std_logic_vector(12 downto 0) := (others => '0'); 

  --ptr
  signal ptr_inc : std_logic := '0';
  signal ptr_dec : std_logic := '0';
  signal ptr_reg : std_logic_vector(12 downto 0) := (others => '0');

  --cnt
  signal cnt_inc : std_logic := '0';
  signal cnt_dec : std_logic := '0';
  signal cnt_reg : std_logic_vector(7 downto 0) := (others => '0');

  signal c : std_logic_vector(7 downto 0) := (others => '0');

  --mux
  signal mux_select1 : std_logic := '0';
  signal mux_select2 : std_logic_vector(1 downto 0) := "00";

  type instr_type is (
		ins_value_inc,		-- +    - 0x2B - Increment value at ptr	           // *ptr+=1;
		ins_value_dec,		-- -    - 0x2D - Decrement value at ptr            // *ptr-=1;
		ins_while_start,	-- [    - 0x5B - If null byte, goto ], else +	     // while (*ptr) {
		ins_while_end,		-- ]    - 0x5D - If not null byte, goto ], else +  // }
		ins_while_break,	-- ~    - 0x7E - End of while                      // break;
		ins_pointer_inc,	-- >    - 0x3E - Next symbol                       // ptr+=1;
		ins_pointer_dec,	-- <    - 0x3C - Previous symbol                   // ptr-=1;
		ins_putchar,		  -- .    - 0x2E - Print value at ptr                // printf("%d", *ptr);
		ins_getchar,		  -- ,    - 0x2C - Read value and put it to ptr      // *ptr = getchar();
		ins_halt,			    -- null	- 0x00 - End program								       // return;
    ins_done,         -- @    - 0x40 - Begin program
		ins_other			    -- else
	);
	signal instr : instr_type;

begin

  -- FSM state register
  State_upd: process(CLK, RESET) is
    begin
      if RESET = '1' then
        -- init <= '0';
        state <= S_START;
      elsif CLK'event and CLK = '1' and EN = '1' then
      -- else 
        state <= next_state;
      end if;
  end process;

  Get_instr: process(DATA_RDATA, CLK)
  begin
    if CLK'event and CLK = '0' then
      instr <= ins_other;
      case DATA_RDATA is
        when X"2B" => instr <= ins_value_inc;
        when X"2D" => instr <= ins_value_dec;
        when X"5B" => instr <= ins_while_start;
        when X"5D" => instr <= ins_while_end;
        when X"7E" => instr <= ins_while_break;
        when X"3E" => instr <= ins_pointer_inc;
        when X"3C" => instr <= ins_pointer_dec;
        when X"2E" => instr <= ins_putchar;
        when X"2C" => instr <= ins_getchar;
        when X"00" => instr <= ins_halt;
        when X"40" => instr <= ins_done;
        when others  => instr <= ins_other;
        end case;
    end if;
  end process Get_instr;

  PC: process(CLK, RESET)
  begin
    if RESET = '1' then
      pc_reg <= (others => '0');
    elsif rising_edge(CLK) then
      if pc_inc = '1' and pc_dec = '0' then
        pc_reg <= pc_reg + 1;
      elsif pc_dec = '1' and pc_inc = '0' then
        pc_reg <= pc_reg - 1;
      elsif pc_dec = '0' and pc_inc = '0' then
        pc_reg <= pc_reg;
      end if;
    end if;
  end process PC;

  PTR: process(CLK, RESET)
  begin
    if RESET = '1' then
      ptr_reg <= (others => '0');
    elsif rising_edge(CLK) then
      -- if ptr_inc = '1' and ptr_dec = '0' then
      if ptr_inc = '1' and ptr_dec = '0' then
        ptr_reg <= ptr_reg + 1;
      elsif ptr_dec = '1' and ptr_inc = '0' then
        ptr_reg <= ptr_reg - 1;
      end if;
    end if;
  end process PTR;

  CNT: process(CLK, RESET)
  begin
    if RESET = '1' then
      cnt_reg <= (others => '0');
    elsif rising_edge(CLK) then
      if cnt_inc = '1' and cnt_dec = '0' then
        cnt_reg <= cnt_reg + 1;
      elsif cnt_dec = '1' and cnt_inc = '0' then
        cnt_reg <= cnt_reg - 1;
      elsif cnt_inc = '1' and cnt_dec = '1' then
        cnt_reg <= X"01";
      end if;

    end if;
  end process CNT;

  MX1: process(CLK, mux_select1, RESET)
    begin
      case mux_select1 is
        when '0'	=> DATA_ADDR <= ptr_reg;
        when '1'	=> DATA_ADDR <= pc_reg;
        when others => --(others => '0')
      end case;
  end process MX1;

  MX2: process(CLK, mux_select2, RESET)
  	begin
      case mux_select2 is
        when "00"	=> DATA_WDATA <= IN_DATA;
        when "01"	=> DATA_WDATA <= DATA_RDATA + 1; -- X"01" -- 1
        when "10"	=> DATA_WDATA <= DATA_RDATA - 1; -- X"01" -- 1
        when "11"	=> DATA_WDATA <= X"00";
        when others => --(others => '0')
      end case;
  end process MX2;

  FSM_logic: process(CLK, EN, state, DATA_RDATA, IN_VLD, OUT_BUSY)
  begin
  -- if CLK'event and CLK = '1' then

    OUT_WE <= '0';
    DATA_RDWR <= '0';
    DATA_EN <= '0';
    DONE <= '0';
    READY <= '0';
    IN_REQ <= '0';
    OUT_DATA <= (others => '0');

    pc_inc <= '0';
    pc_dec <= '0';
    ptr_inc <= '0';
    ptr_dec <= '0';
    cnt_inc <= '0';
    cnt_dec <= '0';

    ----------------------------------------
    -- start
    if state = S_START then
      init <= '0';
      if EN = '1' then
        next_state <= S_PTR_READ;
      else
        next_state <= S_START;
      end if;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- initialize ptr
    if state = S_PTR_READ then
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      pc_inc <= '0';
      ptr_inc <= '0';
      mux_select1 <= '0';

      if DATA_RDATA = X"40" then
        next_state <= S_DONE;
      else
        next_state <= S_PTR_INC;
      end if;
    end if;

    if state = S_PTR_INC then
      ptr_inc <= '1';
      next_state <= S_PTR_READ;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- fetch + transition in read
    if state = S_FETCH_WAIT then
      next_state <= S_FETCH;
    end if;

    if state = S_FETCH then
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      mux_select1 <= '1';
      mux_select2 <= "11";
      pc_inc <= '0';

      next_state <= S_READ_WAIT;
    end if;

    if state = S_READ_WAIT then
      next_state <= S_READ;
    end if;

    if state = S_READ then
      case instr is

        when ins_value_inc => next_state <= S_VALUE_INC1;

        when ins_value_dec => next_state <= S_VALUE_DEC1;

        when ins_while_start => next_state <= S_WHILE_START1;

        when ins_while_end => 
            mux_select1 <= '0';
            DATA_EN <= '1';
            next_state <= S_WHILE_END1;

        when ins_while_break => next_state <= S_WHILE_BREAK1;

        when ins_pointer_inc => next_state <= S_POINTER_INC;
        when ins_pointer_dec => next_state <= S_POINTER_DEC;

        when ins_putchar => next_state <= S_PUTCHAR1;

        when ins_getchar => next_state <= S_GETCHAR1;

        when ins_halt => next_state <= S_HALT;
        when ins_done => next_state <= S_DONE;
        when ins_other => 
          pc_inc <= '1';
          DATA_EN <= '1';
          DATA_RDWR <= '0';
          next_state <= S_FETCH;
        when others => next_state <= S_READ;
      end case;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- done + halt
    if state = S_DONE then
      ptr_inc <= '0';
      READY <= '1';
      pc_dec <= '0';
      pc_inc <= '0';
      next_state <= S_CHECK_HALT;
    end if;

    if state = S_CHECK_HALT then
      if init = '1' then
        next_state <= S_HALT;
      else
        next_state <= S_INIT_DONE;
      end if;
    end if;

    if state = S_INIT_DONE then
      init <= '1';
      next_state <= S_FETCH_WAIT;
    end if;

    if state = S_HALT then
      READY <= '1';
      DONE <= '1';
      next_state <= S_HALT;
    end if;

    ----------------------------------------
    -- increment value at ptr
    if state = S_VALUE_INC1 then
      mux_select1 <= '0';
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      next_state <= S_VALUE_INC2;
    end if;

    if state = S_VALUE_INC2 then
      mux_select2 <= "01";

      DATA_RDWR <= '1';
      DATA_EN <= '1';

      pc_inc <= '1';
      next_state <= S_FETCH;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- decrement value at ptr
    if state = S_VALUE_DEC1 then
      mux_select1 <= '0';
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      next_state <= S_VALUE_DEC2;
    end if;

    if state = S_VALUE_DEC2 then
      mux_select2 <= "10";

      DATA_RDWR <= '1';
      DATA_EN <= '1';

      pc_inc <= '1';
      next_state <= S_FETCH;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- ptr = ptr + 1
    if state = S_POINTER_INC then
      ptr_inc <= '1';
      pc_inc <= '1';
      next_state <= S_FETCH;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- ptr = ptr - 1
    if state = S_POINTER_DEC then
      ptr_dec <= '1';
      pc_inc <= '1';
      next_state <= S_FETCH;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- print value at ptr
    if state = s_PUTCHAR1 then
      mux_select1 <= '0';
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      next_state <= S_PUTCHAR2;
    end if;

    if state = S_PUTCHAR2 then
      if OUT_BUSY = '1' then
        DATA_EN <= '1';
        DATA_RDWR <= '0';
        next_state <= S_PUTCHAR2;
      else
        mux_select1 <= '0';
        pc_inc <= '1';
        OUT_WE <= '1';
        OUT_DATA <= DATA_RDATA;
        next_state <= S_FETCH;
      end if;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- input
    if state = S_GETCHAR1 then
      IN_REQ <= '1';
      mux_select1 <= '0';
      mux_select2 <= "00";
      next_state <= S_GETCHAR2;
    end if;

    if state = S_GETCHAR2 then
      next_state <= S_FETCH_WAIT;
      if IN_VLD = '1' then
        DATA_EN <= '1';
        DATA_RDWR <= '1';
        pc_inc <= '1';
        mux_select1 <= '0';
        next_state <= S_FETCH_WAIT;
      else
        IN_REQ <= '1';
        mux_select2 <= "00";
        next_state <= S_GETCHAR2;
      end if;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- while start
    if state = S_WHILE_START1 then
      pc_inc <= '1';
      mux_select1 <= '0';
      DATA_EN <= '1';
      next_state <= S_WHILE_START1_5;
    end if;

    if state = S_WHILE_START1_5 then
      next_state <= S_WHILE_START2;
    end if;

    if state = S_WHILE_START2 then
      if DATA_RDATA = X"00" then

        -- cnt_reg <= X"01";
        cnt_inc <= '1';
        cnt_dec <= '1';
        -- set to pc
        mux_select1 <= '1';
        DATA_EN <= '1';
        next_state <= S_WHILE_START2_5;
      else
        next_state <= S_FETCH;
      end if;
    end if;

    if state = S_WHILE_START2_5 then
      next_state <= S_WHILE_START3;
    end if;

    if state = S_WHILE_START3 then
      if cnt_reg /= 0 then
        c <= DATA_RDATA;
        next_state <= S_WHILE_START4;
      else
        next_state <= S_FETCH;
      end if;
    end if;

    if state = S_WHILE_START4 then
      if c = X"5B" then -- X"5B" -- [
        cnt_inc <= '1';
      elsif c = X"5D" then -- X"5D" -- ]
        cnt_dec <= '1';
      end if;
      
      pc_inc <= '1';
      DATA_EN <= '1';
      next_state <= S_WHILE_START3;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- while end
    if state = S_WHILE_END1 then
      next_state <= S_WHILE_END2;
    end if;

    if state = S_WHILE_END2 then
      if DATA_RDATA = X"00" then
        pc_inc <= '1';
        next_state <= S_FETCH;
      else

        -- cnt_reg <= X"01";
        cnt_inc <= '1';
        cnt_dec <= '1';

        pc_dec <= '1';

        mux_select1 <= '1';

        -- DATA_EN <= '1';
        next_state <= S_WHILE_END3;
      end if;
    end if;

    if state = S_WHILE_END3 then
      DATA_EN <= '1';
      next_state <= S_WHILE_END4;
    end if;

    if state = S_WHILE_END4 then
      if cnt_reg /= 0 then
        c <= DATA_RDATA;
        next_state <= S_WHILE_END5;
      else
        next_state <= S_FETCH;
      end if;
    end if;

    if state = S_WHILE_END5 then
      if c = X"5D" then -- X"5D" -- ]
        cnt_inc <= '1';
      elsif c = X"5B" then -- X"5B" -- [
        cnt_dec <= '1';
      end if;

      next_state <= S_WHILE_END5_5;
    end if;

    if state = S_WHILE_END5_5 then
      next_state <= S_WHILE_END5_5_5;
    end if;

    if state = S_WHILE_END5_5_5 then
      if cnt_reg = X"00" then
        pc_inc <= '1';
      else
        pc_dec <= '1';
      end if;
      DATA_EN <= '1';
      next_state <= S_WHILE_END4;
    end if;
    ----------------------------------------

    ----------------------------------------
    -- while break
    if state = S_WHILE_BREAK1 then
      pc_inc <= '1';
      ptr_inc <= '1';
      mux_select1 <= '1';
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      next_state <= S_WHILE_BREAK2;
    end if;

    if state = S_WHILE_BREAK2 then
      if DATA_RDATA = X"5D" then
        -- DATA_EN <= '1';
        pc_inc <= '1';
        -- c <= DATA_RDATA;
        next_state <= S_FETCH;
      else
        next_state <= S_WHILE_BREAK1;
      end if;
    end if;
    ----------------------------------------

  end process FSM_logic;
 -- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
 --   - nelze z vice procesu ovladat stejny signal,
 --   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
 --      - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
 --      - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly. 

end behavioral;

