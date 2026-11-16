--  UART7 link to the ADSBee 1421 (devkit 6-pin header):
--     PF7  UART7 TX  ->  ADSBee "UART RX"
--     PF6  UART7 RX  <-  ADSBee "UART TX"
--  8 data bits, no parity, 1 stop bit. Receive is interrupt-driven into a
--  16 KB ring buffer, so bytes are never lost while the main loop is busy
--  redrawing; transmit is polled (only short AT commands are sent).

package Adsb_UART is

   --  Configure the pins and UART7 and start receiving
   procedure Initialize (Baud : Positive);

   --  Change the baud rate. Any byte being received at that moment is lost.
   procedure Set_Baud (Baud : Positive);

   --  Transmit Text and wait until the last bit has left the pin
   procedure Send (Text : String);

   --  Next received byte, if any. Never blocks.
   procedure Get (C : out Character; Available : out Boolean);

   --  Discard everything received so far
   procedure Flush_Input;

   --  Bytes lost because the UART's one-byte holding register was not
   --  read in time (hardware overrun), since start-up
   function Overruns return Natural;

   --  Bytes lost because the ring buffer was full, since start-up
   function Dropped return Natural;

   --  Bytes received (including any later dropped), since start-up
   function Received return Natural;

   --  Bytes with a bad stop bit, since start-up. Many of these mean the
   --  baud rate does not match the other end.
   function Framing_Errors return Natural;

end Adsb_UART;
