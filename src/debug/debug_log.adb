with HAL;          use HAL;
with STM32.Device; use STM32.Device;
with STM32.GPIO;   use STM32.GPIO;
with STM32.USART;  use STM32.USART;

package body Debug_Log is

   --  USART1 TX, routed to the ST-LINK virtual COM port
   TX_Pin : GPIO_Point renames PA9;

   Initialized : Boolean := False;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Enable_Clock (TX_Pin);
      TX_Pin.Configure_IO
        ((Mode_AF, AF    => GPIO_AF_USART1_7, Resistors => Pull_Up,
          AF_Output_Type => Push_Pull, AF_Speed => Speed_50MHz));

      Enable_Clock (USART_1);
      Disable (USART_1);
      Configure
        (USART_1, (Direction => TX, Baud_Rate => Baud_Rate, others => <>));
      Enable (USART_1);
      Initialized := True;
   end Initialize;

   --------------
   -- Put_Char --
   --------------

   procedure Put_Char (C : Character) is
   begin
      loop
         exit when Tx_Is_Empty (USART_1);
      end loop;

      Send (USART_1, UInt8 (Character'Pos (C)));
   end Put_Char;

   --------------
   -- Put_Line --
   --------------

   procedure Put_Line (Line : String) is
   begin
      if not Initialized then
         return;
      end if;

      for C of Line loop
         Put_Char (C);
      end loop;

      Put_Char (ASCII.CR);
      Put_Char (ASCII.LF);
   end Put_Line;

end Debug_Log;
