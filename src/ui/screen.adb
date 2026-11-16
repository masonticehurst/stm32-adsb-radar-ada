with HAL.Framebuffer;
with STM32.Board;     use STM32.Board;
with STM32.FMC;
with STM32_SVD.DMA2D; use STM32_SVD.DMA2D;
with STM32_SVD.FSMC;  use STM32_SVD.FSMC;

package body Screen is

   Map_Layer_Index     : constant := 1;
   Overlay_Layer_Index : constant := 2;

   --  The LTDC, DMA2D and CPU all share the 16-bit SDRAM. The LTDC must be
   --  fed in real time (two full-screen layers, ~38 MB/s), so DMA2D is made
   --  to pause this many AHB clock cycles between its bus accesses to leave
   --  the LTDC room.
   DMA2D_Dead_Time : constant := 8;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      use STM32.FMC;

      procedure Wait_Not_Busy is
      begin
         loop
            exit when not FMC_SDRAM_Busy;
         end loop;
      end Wait_Not_Busy;
   begin
      --  SDRAM fixes, done before the LTDC starts reading it:
      --
      --  CAS latency 3 (the board crate sets 2). This runtime clocks the
      --  CPU at 216 MHz, so the SDRAM clock (HCLK / 2) is 108 MHz, above
      --  what CAS latency 2 allows; the SDRAM part (-6A) is rated 167 MHz
      --  at CAS 3. At CAS 2 data came back wrong: the last word of most
      --  32-byte bursts read as 0xFFFF_FFFF (vertical stripes on the map)
      --  and some low halfwords copied the high one. Tested on the board
      --  2026-11-17: a tile reloaded at CAS 3 was byte-for-byte the file.
      --  The controller field and the SDRAM's own mode register must agree.
      Wait_Not_Busy;
      FMC_Periph.SDCR1.CAS := 3;
      FMC_SDRAM_Cmd
        ((Mode          => FMC_Command_Mode_LoadMode,
          Target        => SDRAM_Bank,
          Mode_Register =>
            (Burst_Length   => SDRAM_Mode_Burst_Length_1,
             Burst_Type     => SDRAM_Mode_Burst_Sequential,
             CAS_Latency    => SDRAM_Mode_CAS_Latency_3,
             Operating_Mode => SDRAM_Mode_Writeburst_Mode_Single)));
      Wait_Not_Busy;

      --  Read burst, and row cycle / self-refresh exit 7 cycles (ST BSP
      --  values; the board crate has 5). Write recovery 3 cycles: RM0385
      --  requires TWR >= TRC - TRCD - TRP = 7 - 2 - 2.
      FMC_Periph.SDCR1.RBURST := True;
      FMC_Periph.SDTR1.TRC    := 6;
      FMC_Periph.SDTR1.TXSR   := 6;
      FMC_Periph.SDTR1.TWR    := 2;

      --  No speculative reads of the unused NOR bank (AN4861)
      FMC_Periph.BCR1.MBKEN := False;

      Display.Initialize (Mode => HAL.Framebuffer.Polling);
      Display.Initialize_Layer (Map_Layer_Index, HAL.Bitmap.RGB_565);
      Display.Initialize_Layer (Overlay_Layer_Index, HAL.Bitmap.ARGB_4444);

      DMA2D_Periph.AMTCR := (EN => True, DT => DMA2D_Dead_Time, others => <>);
   end Initialize;

   ---------------
   -- Map_Layer --
   ---------------

   function Map_Layer return HAL.Bitmap.Any_Bitmap_Buffer is
     (Display.Hidden_Buffer (Map_Layer_Index));

   -------------------
   -- Overlay_Layer --
   -------------------

   function Overlay_Layer return HAL.Bitmap.Any_Bitmap_Buffer is
     (Display.Hidden_Buffer (Overlay_Layer_Index));

   ----------
   -- Show --
   ----------

   procedure Show is
   begin
      Display.Update_Layers;
   end Show;

end Screen;
