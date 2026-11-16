with Ada.Real_Time; use Ada.Real_Time;
with System.Machine_Code;
with HAL.SDMMC;     use HAL.SDMMC;
with SDMMC_Init;
with STM32.Device;  use STM32.Device;
with STM32.GPIO;    use STM32.GPIO;
with STM32.SDMMC;
with STM32_SVD.RCC;
with STM32_SVD.SDMMC;
with Debug_Log;

package body SD_Card is

   package SVD renames STM32_SVD.SDMMC;

   --  SDMMC1 pins on the STM32F746G-DISCO (UM1907): D0..D3, CK, CMD
   SD_Pins       : constant GPIO_Points := (PC8, PC9, PC10, PC11, PC12, PD2);
   SD_Detect_Pin : GPIO_Point renames PC13;

   --  Bus clock for data transfers. The controller is polled without
   --  hardware flow control (the STM32F7 errata advise against it), so
   --  the CPU must empty the FIFO before it overruns. A modest clock keeps
   --  plenty of margin for interrupt latency: ~5.7 MB/s on a 4-bit bus.
   Transfer_Clock : constant := 12_000_000;

   --  Bus clock while writing. Without flow control the CPU must also keep
   --  the transmit FIFO from running dry (an underrun aborts the block), so
   --  writes run slower to leave room for interrupts: half a FIFO lasts
   --  ~32 us at 4 MHz. Writes are rare (screenshots), so speed hardly
   --  matters.
   Write_Clock : constant := 4_000_000;

   --  A read or write that fails (e.g. a FIFO overrun or underrun) is tried
   --  this many times
   Read_Attempts  : constant := 3;
   Write_Attempts : constant := 3;

   --  Longest wait for the card to finish programming (SD spec: 250 ms
   --  per block worst case, usually a few ms for a whole run of blocks)
   Busy_Timeout : constant Time_Span := Milliseconds (1_000);

   Card_Info   : Card_Information;
   Card_Status : Status_Kind := Not_Initialized;

   ---------------------
   -- PLL48_Frequency --
   ---------------------

   --  SDMMC1 is clocked from PLL48CLK = VCO / PLLQ. Despite its name it
   --  is not 48 MHz with this runtime (VCO 400 MHz, PLLQ 7: 57.1 MHz), so
   --  compute the real value from the RCC registers for the divider maths.
   function PLL48_Frequency return UInt32 is
      PLLCFGR : constant STM32_SVD.RCC.PLLCFGR_Register :=
        STM32_SVD.RCC.RCC_Periph.PLLCFGR;
      PLLP : constant UInt32 := (UInt32 (PLLCFGR.PLLP) + 1) * 2;
      PLLQ : constant UInt32 := UInt32 (PLLCFGR.PLLQ);
   begin
      if PLLQ < 2 then
         return 48_000_000;  --  PLL not configured; use the nominal value
      end if;

      return System_Clock_Frequencies.SYSCLK * PLLP / PLLQ;
   end PLL48_Frequency;

   ------------------
   -- Card_Present --
   ------------------

   function Card_Present return Boolean is (not SD_Detect_Pin.Set);

   ------------
   -- Status --
   ------------

   function Status return Status_Kind is (Card_Status);

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      Err : SD_Error;
   begin
      Enable_Clock (SD_Pins & SD_Detect_Pin);

      Configure_IO
        (SD_Pins,
         (Mode           => Mode_AF, AF => GPIO_AF_SDMMC1_12,
          AF_Output_Type => Push_Pull, AF_Speed => Speed_50MHz,
          Resistors      => Pull_Up));

      Configure_IO (SD_Detect_Pin, (Mode => Mode_In, Resistors => Pull_Up));

      if not Card_Present then
         Card_Status := No_Card;
         return;
      end if;

      Enable_Clock (SDMMC_1);
      Reset (SDMMC_1);
      Set_Clock_Source (SDMMC_1, Src_48Mhz);
      STM32.SDMMC.Set_Clk_Src_Speed (SDMMC_1, PLL48_Frequency);

      SDMMC_Init.Card_Identification_Process (SDMMC_1, Card_Info, Err);

      if Err /= OK then
         Card_Status := Card_Error;
         return;
      end if;

      --  Identification may have raised the clock to 25 or 50 MHz; bring it
      --  back down for polled transfers (see Transfer_Clock).
      Set_Clock (SDMMC_Driver'Class (SDMMC_1), Transfer_Clock);

      Card_Status := Ready;

   exception
      when others =>
         --  SDMMC_Init raises Program_Error for unsupported card types
         Card_Status := Card_Error;
   end Initialize;

   -----------------
   -- Short_Pause --
   -----------------

   --  DCTRL must not be written again within 3 SDMMC clocks plus 2 PCLK2
   --  clocks of the last write (RM0385); same idea as stm32_hal's
   --  DCTRL_Write_Delay
   procedure Short_Pause is
   begin
      for J in 1 .. 50 loop
         System.Machine_Code.Asm ("nop", Volatile => True);
      end loop;
   end Short_Pause;

   ------------------
   -- Card_Address --
   ------------------

   --  Address argument of the read/write commands: SDHC/SDXC cards take a
   --  block number, older standard-capacity cards (up to 2 GB, like the
   --  1 GB map card) a byte address
   function Card_Address (Block_Number : UInt64) return UInt32 is
     (UInt32
        (if Card_Info.Card_Type = High_Capacity_SD_Card then Block_Number
         else Block_Number * Block_Size));

   ---------------------
   -- Wait_Card_Ready --
   ---------------------

   --  Poll the card status (CMD13) until it is back in the transfer state
   --  and ready for data, i.e. it has finished programming earlier writes
   function Wait_Card_Ready return Boolean is
      Ready_For_Data : constant UInt32 := 16#100#;  --  R1 bit 8
      Transfer_State : constant UInt32 := 4;        --  R1 bits 12:9
      Deadline       : constant Time   := Clock + Busy_Timeout;
      Err            : SD_Error;
      R1             : UInt32;
   begin
      loop
         Send_Cmd
           (SDMMC_Driver'Class (SDMMC_1), Send_Status,
            Shift_Left (UInt32 (Card_Info.RCA), 16), Err);

         if Err = OK then
            R1 := SVD.SDMMC_Periph.RESP1;
            if (R1 and Ready_For_Data) /= 0
              and then (Shift_Right (R1, 9) and 16#F#) = Transfer_State
            then
               return True;
            end if;
         end if;

         if Clock > Deadline then
            return False;
         end if;
      end loop;
   end Wait_Card_Ready;

   ------------------
   -- Write_Blocks --
   ------------------

   --  One polled single- or multi-block write (CMD24 / CMD25, then CMD12),
   --  in the order of ST's HAL_SD_WriteBlocks. stm32_hal only has a DMA
   --  version, which needs DMA streams and interrupts set up.
   function Write_Blocks (Block_Number : UInt64; Data : Block) return Boolean
   is
      N_Blocks : constant Natural := Data'Length / Block_Size;
      Deadline : constant Time    :=
        Clock + Busy_Timeout + Milliseconds (N_Blocks);
      Idx      : Natural := Data'First;
      Err      : SD_Error;
      Stop_Err : SD_Error;
      Status   : SVD.STA_Register;
      Good     : Boolean;
   begin
      if not Wait_Card_Ready then
         return False;
      end if;

      SVD.SDMMC_Periph.DCTRL := (others => <>);
      Short_Pause;
      STM32.SDMMC.Clear_Static_Flags (SDMMC_1);

      Send_Cmd (SDMMC_Driver'Class (SDMMC_1), Set_Blocklen, Block_Size, Err);
      if Err /= OK then
         return False;
      end if;

      --  Arm the data path, then send the write command
      SVD.SDMMC_Periph.DLEN :=
        (DATALENGTH => SVD.DLEN_DATALENGTH_Field (Data'Length), others => <>);
      Short_Pause;
      SVD.SDMMC_Periph.DCTRL :=
        (DTEN => True, DTDIR => SVD.Controller_To_Card, DTMODE => SVD.Block,
         DBLOCKSIZE => SVD.Block_512B, others => <>);

      Send_Cmd
        (SDMMC_Driver'Class (SDMMC_1),
         (if N_Blocks > 1 then Write_Multi_Block else Write_Single_Block),
         Card_Address (Block_Number), Err);

      if Err = OK then
         --  Keep the FIFO fed: 8 words whenever it is at least half empty
         loop
            Status := SVD.SDMMC_Periph.STA;
            exit when Status.TXUNDERR or else Status.DCRCFAIL
              or else Status.DTIMEOUT or else Status.DATAEND;

            if Status.TXFIFOHE then
               for J in 1 .. 8 loop
                  exit when Idx > Data'Last;
                  SVD.SDMMC_Periph.FIFO :=
                    UInt32 (Data (Idx)) or
                    Shift_Left (UInt32 (Data (Idx + 1)), 8) or
                    Shift_Left (UInt32 (Data (Idx + 2)), 16) or
                    Shift_Left (UInt32 (Data (Idx + 3)), 24);
                  Idx := Idx + 4;
               end loop;
            end if;

            exit when Clock > Deadline;
         end loop;
      end if;

      Status := SVD.SDMMC_Periph.STA;
      Good   :=
        Err = OK and then Status.DATAEND
        and then not
        (Status.TXUNDERR or else Status.DCRCFAIL or else Status.DTIMEOUT);

      --  A multi-block write ends with CMD12, also after an error, so the
      --  card goes back to the transfer state
      if Err = OK and then N_Blocks > 1 then
         Send_Cmd
           (SDMMC_Driver'Class (SDMMC_1), Stop_Transmission, 0, Stop_Err);
         Good := Good and then Stop_Err = OK;
      end if;

      SVD.SDMMC_Periph.DCTRL := (others => <>);
      Short_Pause;
      STM32.SDMMC.Clear_Static_Flags (SDMMC_1);

      --  Wait for the card to finish programming, so a read straight after
      --  works and a programming error shows up here
      return Wait_Card_Ready and then Good;
   end Write_Blocks;

   -----------------
   -- Read_Blocks --
   -----------------

   --  One polled single- or multi-block read (CMD17 / CMD18, then CMD12).
   --  Replaces STM32.SDMMC.Read_Blocks, which reads whatever is still in
   --  the receive FIFO when the transfer ends into a dummy variable instead
   --  of the buffer. If an interrupt delayed the CPU near the end, the tail
   --  of the buffer then kept old contents without any error. In a FAT
   --  sector that sent cluster chains back 128 clusters (seen on the board:
   --  map tiles 512 KB early, then a bad Z10.BIN header).
   function Read_Blocks
     (Block_Number : UInt64; Data : out Block) return Boolean
   is
      N_Blocks : constant Natural := Data'Length / Block_Size;
      Deadline : constant Time    :=
        Clock + Busy_Timeout + Milliseconds (N_Blocks);
      Idx      : Natural := Data'First;
      Polls    : Natural := 0;
      Err      : SD_Error;
      Stop_Err : SD_Error;
      Status   : SVD.STA_Register;
      Good     : Boolean;

      --  Move one word from the FIFO into Data (little-endian)
      procedure Take_Word is
         W : constant UInt32 := SVD.SDMMC_Periph.FIFO;
      begin
         if Idx + 3 <= Data'Last then
            Data (Idx)     := UInt8 (W and 16#FF#);
            Data (Idx + 1) := UInt8 (Shift_Right (W, 8) and 16#FF#);
            Data (Idx + 2) := UInt8 (Shift_Right (W, 16) and 16#FF#);
            Data (Idx + 3) := UInt8 (Shift_Right (W, 24));
         end if;
         Idx := Idx + 4;
      end Take_Word;

   begin
      Data := (others => 0);

      SVD.SDMMC_Periph.DCTRL := (others => <>);
      Short_Pause;
      STM32.SDMMC.Clear_Static_Flags (SDMMC_1);

      Send_Cmd (SDMMC_Driver'Class (SDMMC_1), Set_Blocklen, Block_Size, Err);
      if Err /= OK then
         return False;
      end if;

      --  Arm the data path, then send the read command
      SVD.SDMMC_Periph.DLEN :=
        (DATALENGTH => SVD.DLEN_DATALENGTH_Field (Data'Length), others => <>);
      Short_Pause;
      SVD.SDMMC_Periph.DCTRL :=
        (DTEN => True, DTDIR => SVD.Card_To_Controller, DTMODE => SVD.Block,
         DBLOCKSIZE => SVD.Block_512B, others => <>);

      Send_Cmd
        (SDMMC_Driver'Class (SDMMC_1),
         (if N_Blocks > 1 then Read_Multi_Block else Read_Single_Block),
         Card_Address (Block_Number), Err);

      if Err = OK then
         --  Empty the FIFO 8 words at a time while the data arrives. The
         --  clock is only checked now and then, to keep this loop quick.
         loop
            Status := SVD.SDMMC_Periph.STA;
            exit when Status.RXOVERR or else Status.DCRCFAIL
              or else Status.DTIMEOUT or else Status.DATAEND;

            if Status.RXFIFOHF then
               for J in 1 .. 8 loop
                  Take_Word;
               end loop;
            end if;

            Polls := Polls + 1;
            exit when Polls mod 1_024 = 0 and then Clock > Deadline;
         end loop;

         --  Then keep what is still in the FIFO
         while Idx <= Data'Last and then SVD.SDMMC_Periph.STA.RXDAVL loop
            Take_Word;
         end loop;
      end if;

      Status := SVD.SDMMC_Periph.STA;
      Good   :=
        Err = OK and then Status.DATAEND and then Idx > Data'Last
        and then not
        (Status.RXOVERR or else Status.DCRCFAIL or else Status.DTIMEOUT);

      --  A multi-block read ends with CMD12, also after an error
      if Err = OK and then N_Blocks > 1 then
         Send_Cmd
           (SDMMC_Driver'Class (SDMMC_1), Stop_Transmission, 0, Stop_Err);
         Good := Good and then Stop_Err = OK;
      end if;

      --  Each failed attempt is logged (it is retried by Read)
      if not Good then
         Debug_Log.Put_Line
           ("sd read fail: blk" & Block_Number'Image & " n" & N_Blocks'Image &
            " err " & Err'Image & " stop " &
            (if N_Blocks > 1 and then Err = OK then Stop_Err'Image else "-") &
            " dataend " & Status.DATAEND'Image & " ovr " &
            Status.RXOVERR'Image & " crc " & Status.DCRCFAIL'Image & " tmo " &
            Status.DTIMEOUT'Image & " got" & Integer'Image (Idx - Data'First) &
            "/" & Data'Length'Image);
      end if;

      SVD.SDMMC_Periph.DCTRL := (others => <>);
      Short_Pause;
      STM32.SDMMC.Clear_Static_Flags (SDMMC_1);

      return Good;
   end Read_Blocks;

   ----------
   -- Read --
   ----------

   overriding function Read
     (This : in out SD_Block_Device; Block_Number : UInt64; Data : out Block)
      return Boolean
   is
      pragma Unreferenced (This);
      Done : Boolean := False;
   begin
      if Card_Status /= Ready or else Data'Length = 0 then
         return False;
      end if;

      --  An overrun (CPU held up by interrupts) or CRC error is retried
      for Attempt in 1 .. Read_Attempts loop
         Done := Read_Blocks (Block_Number, Data);
         exit when Done;
      end loop;

      return Done;

   exception
      when others =>
         return False;
   end Read;

   -----------
   -- Write --
   -----------

   overriding function Write
     (This : in out SD_Block_Device; Block_Number : UInt64; Data : Block)
      return Boolean
   is
      pragma Unreferenced (This);
      Done : Boolean := False;
   begin
      if Card_Status /= Ready or else Data'Length = 0 then
         return False;
      end if;

      Set_Clock (SDMMC_Driver'Class (SDMMC_1), Write_Clock);

      for Attempt in 1 .. Write_Attempts loop
         Done := Write_Blocks (Block_Number, Data);
         exit when Done;
      end loop;

      Set_Clock (SDMMC_Driver'Class (SDMMC_1), Transfer_Clock);
      return Done;

   exception
      when others =>
         Set_Clock (SDMMC_Driver'Class (SDMMC_1), Transfer_Clock);
         return False;
   end Write;

end SD_Card;
