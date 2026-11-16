with Ada.Interrupts.Names;
with System;

with HAL;             use HAL;
with STM32.Device;    use STM32.Device;
with STM32.GPIO;      use STM32.GPIO;
with STM32_SVD.USART; use STM32_SVD.USART;

package body GPS_UART is

   TX_Pin : GPIO_Point renames PC6;
   RX_Pin : GPIO_Point renames PC7;

   Port : USART_Peripheral renames USART6_Periph;

   --  9600 baud is under 1 KB/s, so this holds a couple of seconds
   Buffer_Size : constant := 2_048;
   type Buffer_Index is mod Buffer_Size;
   type Char_Buffer is array (Buffer_Index) of Character;

   --  Count up without ever overflowing
   procedure Bump (N : in out Natural) with
      Inline;

   procedure Bump (N : in out Natural) is
   begin
      if N < Natural'Last then
         N := N + 1;
      end if;
   end Bump;

   --------------
   -- Receiver --
   --------------

   protected Receiver with
      Interrupt_Priority => System.Interrupt_Priority'First
   is
      procedure Get (C : out Character; Available : out Boolean);
      function Received_Count return Natural;
      function Lost_Count return Natural;
      function Framing_Count return Natural;
   private
      procedure Handler with
         Attach_Handler => Ada.Interrupts.Names.USART6_Interrupt;

      Buf      : Char_Buffer;
      Head     : Buffer_Index := 0;  --  next slot to write
      Tail     : Buffer_Index := 0;  --  next slot to read
      Count    : Natural      := 0;
      Received : Natural      := 0;
      Lost     : Natural      := 0;
      Framing  : Natural      := 0;
   end Receiver;

   protected body Receiver is

      procedure Get (C : out Character; Available : out Boolean) is
      begin
         if Count = 0 then
            C         := ASCII.NUL;
            Available := False;
         else
            C         := Buf (Tail);
            Tail      := Tail + 1;
            Count     := Count - 1;
            Available := True;
         end if;
      end Get;

      function Received_Count return Natural is (Received);
      function Lost_Count return Natural is (Lost);
      function Framing_Count return Natural is (Framing);

      --  USART6 interrupt: a byte arrived, or an error. An overrun keeps
      --  raising this interrupt until it is cleared, so every error flag
      --  is cleared here.
      procedure Handler is
         Status : constant ISR_Register := Port.ISR;
         C      : Character;
      begin
         if Status.ORE then
            Bump (Lost);
         end if;

         if Status.FE then
            Bump (Framing);
         end if;

         if Status.ORE or else Status.FE or else Status.NF or else Status.PE
         then
            Port.ICR :=
              (ORECF => Status.ORE, FECF => Status.FE, NCF => Status.NF,
               PECF  => Status.PE, others => <>);
         end if;

         if Status.RXNE then
            --  Reading RDR clears RXNE
            C := Character'Val (Natural (Port.RDR.RDR) mod 256);
            Bump (Received);

            if Count < Buffer_Size then
               Buf (Head) := C;
               Head       := Head + 1;
               Count      := Count + 1;
            else
               Bump (Lost);
            end if;
         end if;
      end Handler;

   end Receiver;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize (Baud : Positive) is
      Config : constant GPIO_Port_Configuration :=
        (Mode => Mode_AF, AF => GPIO_AF_USART6_8, AF_Output_Type => Push_Pull,
         AF_Speed => Speed_50MHz, Resistors => Pull_Up);

      --  USART6 is clocked from APB2. With 16x oversampling BRR is simply
      --  clock / baud, rounded to the nearest integer.
      Clock   : constant UInt32 := System_Clock_Frequencies.PCLK2;
      Divider : constant UInt32 := (Clock + UInt32 (Baud) / 2) / UInt32 (Baud);
   begin
      Enable_Clock (GPIO_Points'(TX_Pin, RX_Pin));
      Configure_IO (TX_Pin, Config);
      Configure_IO (RX_Pin, Config);

      Enable_Clock (USART_6);
      Port.CR1 := (others => <>);  --  disabled; 8N1, 16x oversampling
      Port.CR2 := (others => <>);
      Port.CR3 := (others => <>);

      Port.BRR :=
        (DIV_Fraction => BRR_DIV_Fraction_Field (Divider mod 16),
         DIV_Mantissa => BRR_DIV_Mantissa_Field (Divider / 16), others => <>);

      --  The transmitter is enabled only so the TX line idles high
      Port.CR1 :=
        (UE     => True,
         RE     => True,
         TE     => True,
         RXNEIE => True,  --  interrupt on each byte (and on overrun)
         others => <>);
   end Initialize;

   ---------
   -- Get --
   ---------

   procedure Get (C : out Character; Available : out Boolean) is
   begin
      Receiver.Get (C, Available);
   end Get;

   function Received return Natural is (Receiver.Received_Count);

   function Lost return Natural is (Receiver.Lost_Count);

   function Framing_Errors return Natural is (Receiver.Framing_Count);

end GPS_UART;
