--  USART6 link to the GT-U7 GPS module (Arduino header D0/D1):
--     PC6  USART6 TX  (D1)  ->  GPS "RXD"
--     PC7  USART6 RX  (D0)  <-  GPS "TXD"
--  8 data bits, no parity, 1 stop bit

package GPS_UART is

   --  Configure the pins and USART6 and start receiving
   procedure Initialize (Baud : Positive);

   --  Next received byte, if any. Never blocks.
   procedure Get (C : out Character; Available : out Boolean);

   --  Bytes received (including any later dropped), since start-up
   function Received return Natural;

   --  Bytes lost to a hardware overrun or a full buffer, since start-up
   function Lost return Natural;

   --  Bytes with a bad stop bit, since start-up. Many of these mean the
   --  baud rate does not match the module.
   function Framing_Errors return Natural;

end GPS_UART;
